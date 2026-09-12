#!/usr/bin/env python3
"""DevWatch backend — one-shot CLI called from the Omarchy shell plugin.

Subcommands:
  status    Emits a JSON snapshot of all configured dev services.
  start     Start a service:   devwatch.py start <project> <service>
  stop      Stop a service:    devwatch.py stop  <project> <service>
  restart   Restart a service: devwatch.py restart <project> <service>

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

Exit codes: 0 ok, 1 usage, 2 target not found, 3 action failed.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CONFIG_PATH = os.path.join(HOME, ".config", "devwatch", "config.json")
PROJECTS_DIR = os.path.join(HOME, "Projects")
MAX_BYTES = 65536


def load_config():
    paths = [PROJECTS_DIR]
    try:
        with open(CONFIG_PATH) as f:
            extra = json.load(f).get("scan_paths", [])
        for p in extra:
            if os.path.isdir(p) and p not in paths:
                paths.append(p)
    except (OSError, ValueError):
        pass
    return paths


def find_projects():
    projects = {}
    for base in load_config():
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
            if name in projects:
                name = base.replace("/", "_") + "_" + name
            projects[name] = {"path": proj, "services": services}
    return projects


def port_open(port):
    if not port:
        return None
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=0.3):
            return True
    except OSError:
        return False


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

    if stype == "compose":
        _, res = compose_cmd(proj_path, svc)
        name = svc.get("name", "").lower()
        lines = [l for l in res.stdout.splitlines()[1:] if l.strip()]
        if res.returncode != 0:
            out["detail"] = "docker compose Fehler"
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
        out["detail"] = f"pid {pid}" if alive else "gestoppt"

    else:
        out["detail"] = f"unbekannter Typ: {stype}"

    po = port_open(out.get("port"))
    if po is not None:
        out["port_open"] = po
    return out


def snapshot():
    projects = find_projects()
    result = {}
    for pname, proj in projects.items():
        svcs = []
        for svc in proj["services"]:
            entry = {"name": svc.get("name", "?"), "type": svc.get("type", "?")}
            entry.update(svc_status(proj["path"], svc))
            svcs.append(entry)
        if svcs:
            result[pname] = {"path": proj["path"], "services": svcs}
    payload = json.dumps({"projects": result}, ensure_ascii=False)
    sys.stdout.write(payload[:MAX_BYTES])
    sys.stdout.write("\n")


def resolve(projects, pname, sname):
    proj = projects.get(pname)
    if not proj:
        print(f"Projekt nicht gefunden: {pname}", file=sys.stderr)
        sys.exit(2)
    for svc in proj["services"]:
        if svc.get("name") == sname:
            return proj, svc
    print(f"Dienst nicht gefunden: {sname}", file=sys.stderr)
    sys.exit(2)


def do_start(proj_path, svc):
    stype = svc.get("type")
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
        # Already running?
        try:
            with open(pidfile) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            print("Läuft bereits.", file=sys.stderr)
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
    print(f"Start nicht unterstützt für Typ: {stype}", file=sys.stderr)
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
    if stype == "compose":
        cmd = ["docker", "compose"]
        if svc.get("file"):
            cmd += ["-f", os.path.join(proj_path, svc["file"])]
        cmd.append("stop")
        if svc.get("service_name"):
            cmd.append(svc["service_name"])
        return subprocess.run(cmd, cwd=proj_path).returncode == 0
    if stype == "systemd":
        return subprocess.run(["systemctl", "--user", "stop", svc.get("unit", "")]).returncode == 0
    if stype == "cmd":
        pidfile = os.path.join(proj_path, svc.get("pidfile", f".devwatch-{svc.get('name','x')}.pid"))
        pid, start_time = read_pid_identity(pidfile)
        if not pid:
            print("Kein PID-Eintrag.", file=sys.stderr)
            return True
        if not proc_alive_with_identity(pid, start_time):
            print("Prozess existiert nicht mehr oder PID wurde recycelt.", file=sys.stderr)
            os.remove(pidfile)
            return True
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
        return True
    print(f"Stop nicht unterstützt für Typ: {stype}", file=sys.stderr)
    return False


def main():
    args = sys.argv[1:]
    if not args or args[0] == "status":
        snapshot()
        return
    if len(args) != 3 or args[0] not in ("start", "stop", "restart"):
        print(__doc__)
        sys.exit(1)
    action, pname, sname = args
    projects = find_projects()
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
