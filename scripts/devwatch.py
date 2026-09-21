#!/usr/bin/env python3
"""DevWatch backend — one-shot CLI called from the Omarchy shell plugin.

Subcommands:
  status    Emits a JSON snapshot of all configured dev services.
  start     Start a service:   devwatch.py start <project> <service>
  stop      Stop a service:    devwatch.py stop  <project> <service>
  restart   Restart a service: devwatch.py restart <project> <service>
  groupstart   Start every service of a group:  devwatch.py groupstart <project>
  groupstop    Stop only the running ones:      devwatch.py groupstop  <project>

Service definitions live in .devservices.json files inside each project
directory. Scan paths default to ~/Projects and can be extended via
~/.config/devwatch/config.json: {"scan_paths": ["/abs/path", ...]}

Service entry format (.devservices.json):
{
  "services": [
    {"name": "db",       "type": "compose", "file": "docker-compose.yml"},
    {"name": "api",      "type": "systemd", "unit": "myapp.service"},
    {"name": "web",      "type": "cmd",
     "command": "php -S localhost:8080 -t public", "cwd": ".", "port": 8080,
     "pidfile": ".devwatch-web.pid"}
  ]
}

Optional per service:
- "firewall": true  — open (start) / close (stop) the port via UFW.
- Grouping: a file with >1 service becomes one group; "group": {"name": "..."}
  or top-level "group_name" sets the name (fallback: project key). Setting
  "group": false disables grouping.

Exit codes: 0 ok, 1 usage, 2 target not found, 3 action failed.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time

UFW = "/usr/sbin/ufw"

HOME = os.path.expanduser("~")
CONFIG_PATH = os.path.join(HOME, ".config", "devwatch", "config.json")
PROJECTS_DIR = os.path.join(HOME, "Projects")
MAX_BYTES = 65536


def load_config():
    """Determine scan base dirs: default ~/Projects + scan_paths from config.

    Returns (paths, warnings). warnings lists invalid (typo/missing) entries
    from the config, so the status snapshot can report them visibly.
    """
    paths = [PROJECTS_DIR]
    warnings = []
    try:
        with open(CONFIG_PATH) as f:
            extra = json.load(f).get("scan_paths", [])
    except (OSError, ValueError):
        extra = []
    for p in extra:
        if not isinstance(p, str) or not p.strip():
            warnings.append("config: invalid scan_path entry (empty/non-text)")
            continue
        # Tilde (~, ~user) und ${VAR}-Umgebungsvariablen expandieren — damit
        # schreiben Nutzer "~/code" oder "${HOME}/arbeit" statt absoluter Pfade.
        expanded = os.path.expandvars(os.path.expanduser(p.strip()))
        if not os.path.isdir(expanded):
            warnings.append(f"config: scan_path does not exist: {p}")
            continue
        if expanded not in paths:
            paths.append(expanded)
    return paths, warnings


def find_projects():
    projects = {}
    bases, config_warnings = load_config()
    for base in bases:
        try:
            entries = sorted(os.listdir(base))
        except OSError:
            continue
        for name in entries:
            proj = os.path.join(base, name)
            decl = os.path.join(proj, ".devservices.json")
            if not os.path.isfile(decl):
                continue
            try:
                with open(decl) as f:
                    data = json.load(f)
                services = data.get("services", [])
            except (OSError, ValueError):
                services = []
                data = {}
            if name in projects:
                name = base.replace("/", "_") + "_" + name
            # Carry group metadata (dict with name or bool false) + group_name,
            # so snapshot() can decide on grouping.
            projects[name] = {
                "path": proj,
                "services": services,
                "group": data.get("group"),
                "group_name": data.get("group_name"),
            }
    return projects, config_warnings


def port_open(port):
    if not port:
        return None
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, int(port)), timeout=0.3):
                return True
        except OSError:
            continue
    return False


def adopt_port_owner(port):
    """Find the PID listening on <port> (any address, IPv4+IPv6) and verify
    its /proc identity. Returns (pid, starttime) or None."""
    try:
        res = subprocess.run(["ss", "-H", "-ltnp"], capture_output=True,
                             text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    needle = f":{int(port)} "
    for line in res.stdout.splitlines():
        if needle not in line:
            continue
        idx = line.find("users:((")
        if idx == -1:
            continue
        for chunk in line[idx:].split(","):
            chunk = chunk.strip().strip('"))(( ')
            if chunk.startswith("pid="):
                try:
                    pid = int(chunk[4:])
                except ValueError:
                    continue
                try:
                    starttime = open(f"/proc/{pid}/stat", "rb").read().split()[21].decode()
                    return pid, starttime
                except (OSError, IndexError):
                    continue
    return None


def ufw_result(port, action):
    """Run a ufw action (allow/delete) via NOPASSWD-sudo.

    Return (ok, detail). Errors are NEVER raised — start/stop does not abort,
    the state is reported honestly.
    """
    try:
        # ufw-Syntax: `ufw allow <port>` und `ufw delete allow <port>` — das
        # `allow`-Schluesselwort darf bei delete NICHT fehlen, sonst antwortet
        # ufw "Could not find rule" und der Port bleibt offen.
        if action == "delete":
            cmd = ["sudo", "-n", UFW, "delete", "allow", str(port)]
        else:
            cmd = ["sudo", "-n", UFW, "allow", str(port)]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if res.returncode == 0:
            return True, "ufw ok"
        err = (res.stderr or res.stdout).strip()
        return False, f"ufw error ({res.returncode}): {err}"
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"ufw error: {e}"


def ufw_allowed(port):
    """Check whether <port> is allowed in the ufw status.

    Return (allowed, detail); allowed=None when ufw is not checkable
    (no NOPASSWD). Errors are never raised.
    """
    try:
        res = subprocess.run(["sudo", "-n", UFW, "status", "numbered"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"ufw status error: {e}"
    if res.returncode != 0:
        err = (res.stderr or res.stdout).strip()
        return None, f"ufw status error ({res.returncode}): {err}"
    needle = f":{port}"
    for line in res.stdout.splitlines():
        if needle in line and ("ALLOW" in line.upper() or "ALLOW IN" in line.upper()):
            return True, "ufw open"
    return False, "ufw closed"


def firewalls(svc):
    """True, wenn der Dienst eine Firewall-Regel bekommen darf (firewall+port)."""
    return bool(svc.get("firewall")) and bool(svc.get("port"))


def compose_cmd(proj_path, svc):
    cmd = ["docker", "compose"]
    if svc.get("file"):
        cmd += ["-f", os.path.join(proj_path, svc["file"])]
    cmd.append("ps")
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=10,
                         env={**os.environ, "DOCKER_CONFIG": os.environ.get("DOCKER_CONFIG", "")})
    return cmd[:-1], res


def svc_status(proj_path, svc):
    stype = svc.get("type")
    out = {"running": False, "detail": "", "port": svc.get("port")}
    out["firewall"] = bool(svc.get("firewall"))
    # allowed: true when firewall+port and ufw reports the port open;
    # false when closed; None when no firewall/port or ufw not checkable.
    out["allowed"] = None
    if firewalls(svc):
        allowed, fdet = ufw_allowed(svc.get("port"))
        out["allowed"] = allowed
        # Nur ECHTE Fehler (kein sudo/kein NOPASSWD/Timeout) kurz im Panel melden;
        # der volle stderr-Text landet in do_start/do_stop im Log. offen/zu zeigt
        # das Panel über allowed ✓/✕.
        if allowed is None and fdet:
            out["fw_detail"] = "ufw not set up"

    if stype == "compose":
        _, res = compose_cmd(proj_path, svc)
        name = svc.get("name", "").lower()
        lines = [l for l in res.stdout.splitlines()[1:] if l.strip()]
        if res.returncode != 0:
            out["detail"] = "docker compose error"
            return out
        if name:
            hit = [l for l in lines if name in l.lower()]
            out["running"] = bool(hit) and "exited" not in hit[0].lower()
            out["detail"] = hit[0].split()[3] if hit and len(hit[0].split()) > 3 else (f"{len(lines)} Container" if lines else "kein Container")
        else:
            out["running"] = bool(lines)
            out["detail"] = f"{len(lines)} Container" if lines else "kein Container"

    elif stype == "systemd":
        unit = svc.get("unit", "")
        res = subprocess.run(["systemctl", "--user", "is-active", unit],
                             capture_output=True, text=True, timeout=5)
        state = res.stdout.strip()
        out["running"] = state == "active"
        out["detail"] = state

    elif stype == "cmd":
        pidfile = os.path.join(proj_path, svc.get("pidfile", f".devwatch-{svc.get('name','x')}.pid"))
        pid = None
        try:
            with open(pidfile) as f:
                pid = int(f.read().strip())
        except (OSError, ValueError):
            pass
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    alive = bool(f.read())
            except (OSError, ValueError):
                alive = False
        out["running"] = alive
        out["detail"] = f"pid {pid}" if alive else "stopped"

    else:
        out["detail"] = f"unknown type: {stype}"

    po = port_open(out.get("port"))
    if po is not None:
        out["port_open"] = po
    return out


def snapshot():
    projects, config_warnings = find_projects()
    result = {}
    for pname, proj in projects.items():
        svcs = []
        for svc in proj["services"]:
            entry = {"name": svc.get("name", "?"), "type": svc.get("type", "?")}
            entry.update(svc_status(proj["path"], svc))
            svcs.append(entry)
        if not svcs:
            continue
        # Gruppiert?: >1 Dienst UND nicht explizit "group": false.
        # Gruppenname: "group": {"name":...} → group_name top-level → Projekt-Key.
        grouped = len(svcs) > 1 and proj.get("group") is not False
        if grouped:
            gname = None
            gc = proj.get("group")
            if isinstance(gc, dict):
                gname = gc.get("name")
            if not gname:
                gname = proj.get("group_name")
            result[pname] = {"path": proj["path"],
                             "group": {"name": gname or pname, "services": svcs}}
        else:
            result[pname] = {"path": proj["path"], "services": svcs}
    payload = json.dumps({"projects": result, "config_warnings": config_warnings},
                         ensure_ascii=False)
    sys.stdout.write(payload[:MAX_BYTES])
    sys.stdout.write("\n")


def resolve(projects, pname, sname):
    proj = projects.get(pname)
    if not proj:
        print(f"Project not found: {pname}", file=sys.stderr)
        sys.exit(2)
    for svc in proj["services"]:
        if svc.get("name") == sname:
            return proj, svc
    print(f"Service not found: {sname}", file=sys.stderr)
    sys.exit(2)


def do_start(proj_path, svc):
    stype = svc.get("type")
    # Open the firewall port before start (never crash, log errors).
    if firewalls(svc):
        ok, detail = ufw_result(svc["port"], "allow")
        if not ok:
            print(detail, file=sys.stderr)
    if stype == "compose":
        cmd = ["docker", "compose"]
        if svc.get("file"):
            cmd += ["-f", os.path.join(proj_path, svc["file"])]
        cmd.append("up")
        if svc.get("detached", True):
            cmd.append("-d")
        return subprocess.run(cmd, cwd=proj_path).returncode == 0
    if stype == "systemd":
        return subprocess.run(["systemctl", "--user", "start", svc.get("unit", "")]).returncode == 0
    if stype == "cmd":
        pidfile = os.path.join(proj_path, svc.get("pidfile", f".devwatch-{svc.get('name','x')}.pid"))
        port = svc.get("port")
        # Port schon von irgendeinem Prozess belegt? (z.B. von einer anderen
        # Sitzung manuell gestartet) → den Prozess adoptieren statt einen
        # Zombie-Eintrag zu erzeugen, der "Failed to listen" produziert.
        if port and port_open(port):
            adopted = adopt_port_owner(port)
            if adopted:
                pid, start_time = adopted
                with open(pidfile, "w") as f:
                    f.write(str(pid))
                print(f"Port {port} already in use — adopted process {pid}.", file=sys.stderr)
                return True
            print(f"Port {port} in use, owner not identifiable.", file=sys.stderr)
            return False
        # Already running?
        try:
            with open(pidfile) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            print("Already running.", file=sys.stderr)
            return True
        except (OSError, ValueError):
            pass
        logfile = os.path.join(proj_path, ".devwatch-" + svc.get("name", "x") + ".log")
        with open(logfile, "ab") as log:
            proc = subprocess.Popen(svc["command"], shell=True, cwd=proj_path,
                                    stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        with open(pidfile, "w") as f:
            f.write(str(proc.pid))
        time.sleep(0.3)
        return proc.poll() is None
    print(f"Start not supported for type: {stype}", file=sys.stderr)
    return False


def proc_alive_with_identity(pid, start_time):
    """Verify /proc/<pid> still refers to the same process we started."""
    try:
        os.kill(pid, 0)
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().split()
        return fields[21].decode() == str(start_time)
    except (OSError, IndexError, ValueError):
        return False


def read_pid_identity(pidfile):
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().split()
        return pid, fields[21].decode()
    except (OSError, IndexError, ValueError):
        return None, None


def do_stop(proj_path, svc):
    stype = svc.get("type")
    ok = True
    if stype == "compose":
        cmd = ["docker", "compose"]
        if svc.get("file"):
            cmd += ["-f", os.path.join(proj_path, svc["file"])]
        cmd.append("stop")
        if svc.get("service_name"):
            cmd.append(svc["service_name"])
        ok = subprocess.run(cmd, cwd=proj_path).returncode == 0
    elif stype == "systemd":
        ok = subprocess.run(["systemctl", "--user", "stop", svc.get("unit", "")]).returncode == 0
    elif stype == "cmd":
        pidfile = os.path.join(proj_path, svc.get("pidfile", f".devwatch-{svc.get('name','x')}.pid"))
        pid, start_time = read_pid_identity(pidfile)
        if not pid:
            print("No PID entry.", file=sys.stderr)
        elif not proc_alive_with_identity(pid, start_time):
            print("Process no longer exists or PID was recycled.", file=sys.stderr)
            os.remove(pidfile)
        else:
            os.kill(pid, signal.SIGTERM)
            for _ in range(30):
                time.sleep(0.2)
                if not proc_alive_with_identity(pid, start_time):
                    break
            else:
                os.kill(pid, signal.SIGKILL)
            try:
                os.remove(pidfile)
            except OSError:
                pass
    else:
        print(f"Stop not supported for type: {stype}", file=sys.stderr)
        return False
    # Close the firewall port AFTER the process ended (never crash, log errors).
    if firewalls(svc):
        aok, adetail = ufw_result(svc["port"], "delete")
        if not aok and adetail:
            print(adetail, file=sys.stderr)
    return ok


def main():
    args = sys.argv[1:]
    if not args or args[0] == "status":
        snapshot()
        return
    if args[0] == "groupstart" or args[0] == "groupstop":
        if len(args) != 2:
            print(__doc__)
            sys.exit(1)
        action, pname = args
        projects, _ = find_projects()
        proj = projects.get(pname)
        if not proj:
            print(f"Project not found: {pname}", file=sys.stderr)
            sys.exit(2)
        proj_path = proj["path"]
        targets = proj["services"]
        ok = True
        for svc in targets:
            if action == "groupstop":
                # Nur laufende der Gruppe stoppen (sequenziell, kein Port-Race).
                st = svc_status(proj_path, svc)
                if not st["running"]:
                    continue
                if not do_stop(proj_path, svc):
                    ok = False
            else:
                # groupstart: alle (do_start/adopt_logik verhindern Port-Race).
                if not do_start(proj_path, svc):
                    ok = False
        sys.exit(0 if ok else 3)
    if len(args) != 3 or args[0] not in ("start", "stop", "restart"):
        print(__doc__)
        sys.exit(1)
    action, pname, sname = args
    projects, _ = find_projects()
    proj, svc = resolve(projects, pname, sname)
    proj_path = proj["path"]
    ok = True
    if action == "start":
        ok = do_start(proj_path, svc)
    elif action == "stop":
        ok = do_stop(proj_path, svc)
    elif action == "restart":
        ok = do_stop(proj_path, svc)
        if not ok:
            sys.exit(3)
        ok = do_start(proj_path, svc)
    sys.exit(0 if ok else 3)


if __name__ == "__main__":
    main()
