# DevWatch

Project-based dev-service manager as an **Omarchy bar widget**: local dev
services (Docker Compose, systemd-user, custom commands) grouped by project,
with start/stop/restart right from the bar.

> **Requirement:** Omarchy (Quickshell-based shell). DevWatch is an Omarchy
> plugin and only runs there — not on GNOME/KDE/XFCE. Otherwise it works on any
> Linux running Omarchy.

## Installation

```bash
omarchy plugin add https://github.com/SeBoOne/omarchy-devwatch.git --enable
```

Disable or remove:

```bash
omarchy plugin disable sebo.devwatch      # keeps files, just hides the widget
omarchy plugin remove sebo.devwatch       # uninstall (removes the plugin folder)
```

Development: edit in `~/Projects/devwatch/`, then copy the changed files to
`~/.config/omarchy/plugins/sebo.devwatch/` (hot-reload is active). After adding
new files or manifest changes, run `omarchy-shell shell rescanPlugins` (and, if
registration stays stale, `omarchy restart shell`).

**Firewall support (optional):** The `"firewall": true` field (see below) uses
`ufw`. UFW is part of the Omarchy base installation
(`install/omarchy-base.packages`), so it is already present — no setup step
needed.

## Declaring services

Place a `.devservices.json` in the project folder (e.g. `~/Projects/<projekt>/`):

```json
{
  "services": [
    {"name": "db",  "type": "compose", "file": "docker-compose.yml"},
    {"name": "api", "type": "systemd", "unit": "myapp.service"},
    {"name": "web", "type": "cmd", "command": "php -S localhost:8080 -t public",
     "cwd": ".", "port": 8080, "pidfile": ".devwatch-web.pid"},
    {"name": "mail", "type": "cmd", "command": "php -S localhost:8090 -t public",
     "cwd": ".", "port": 8090, "pidfile": ".devwatch-mail.pid", "firewall": true}
  ]
}
```

- `compose`: `docker compose up -d` / `stop` in the project folder; optional
  `file` and `service_name` to target a single container.
- `systemd`: `systemctl --user start/stop <unit>`.
- `cmd`: runs the command in its own session, PID + log file in the project
  (`.devwatch-<name>.log`). Stop via SIGTERM, verifies PID identity (/proc start
  time) before killing, escalates to SIGKILL after 6 s.
- `port`: optional TCP check (IPv4 + IPv6) shown as an health indicator.
- `firewall`: optional field (only applies when `port` is set). On start runs
  `sudo -n ufw allow <port>`, on stop `sudo -n ufw delete allow <port>`. Needs a
  NOPASSWD sudo rule (see `scripts/setup-ufw-sudoers.sh`). If permission is
  missing, the status reports a real firewall error (`allowed: false`); the
  service still starts/stops, the backend does NOT abort.

## Grouping

A `.devservices.json` with **>1 service** becomes **one group** in the panel (a
single switch instead of per-service rows). With **==1 service** it stays a
single switch. A multi-service file can opt out of grouping via `"group": false`
(stays as individual services).

Group name: `"group": {"name": "..."}` or top-level `"group_name"`; fallback is
the project key (folder name):

```json
{
  "group_name": "Hearth & Hammer",
  "services": [
    {"name": "web", "type": "cmd", "command": "python3 -m http.server 8090",
     "cwd": ".", "port": 8090, "pidfile": ".devwatch-web.pid"},
    {"name": "api", "type": "cmd", "command": "php -S localhost:8091 -t public",
     "cwd": ".", "port": 8091, "pidfile": ".devwatch-api.pid"}
  ]
}
```

Group switch in the panel: **left-click** starts all services in the group (when
none is running), a **double-click flow** stops all running ones. **Right-click**
opens the drill-down subview with the group's individual services (start/stop as
usual) plus a "back to overview" entry.

## Additional scan paths

DevWatch only watches `~/Projects/` by default. Point it at any additional
folders via a small config:

`~/.config/devwatch/config.json`:

```json
{
  "scan_paths": [
    "~/code",
    "${HOME}/work",
    "/absolute/path"
  ]
}
```

- Every entry is expanded for **`~/` tilde** and **`${VAR}` environment
  variables**; relative/absolute paths work too.
- Every **subdirectory** of a scan path that contains a `.devservices.json`
  appears in the widget (same as `~/Projects/`).
- **Important:** invalid entries (typos, non-existent folders, empty strings)
  are ignored and reported as a **configuration error** in the panel (red hint
  instead of silent failure).
- The file does not have to exist — without it, only the default `~/Projects/`
  is used.

## UI

- Bar widget (green when at least one service runs), click opens the panel.
- One click on a running service requests stop (confirm); click again to stop. A
  stopped service: click to start.
## Keyboard

- ↑/↓ navigate, Enter = start/stop (confirm), Esc = close.
- **→ (Right) in the overview opens the focused group** (drill-down into its
  individual services); **← (Left) returns to the overview**. Group switch on
  Enter/Space still starts/stops the whole group.

## Optional: keyboard shortcut for the panel

The panel can be toggled (open/close) from a terminal at any time with
`omarchy-shell shell toggle sebo.devwatch`. To bind that to a key, add a
binding to `~/.config/hypr/bindings.lua` (no extra plugin needed):

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + SHIFT + D", "DevWatch", "omarchy-shell shell toggle sebo.devwatch")
```

If the key is already bound by Omarchy defaults pick another key if u dont want to change it, else:

```lua
hl.unbind("SUPER + SHIFT + D")
o.bind("SUPER + SHIFT + D", "DevWatch", "omarchy-shell shell toggle sebo.devwatch")
```

Reload Hyprland config (usually auto-applied on save; if not, `hyprctl reload`)
— DevWatch then opens/closes with one keypress.

## Backend (CLI)

```bash
python3 scripts/devwatch.py status                 # JSON snapshot
python3 scripts/devwatch.py start <project> <service>
python3 scripts/devwatch.py stop  <project> <service>
python3 scripts/devwatch.py restart <project> <service>
python3 scripts/devwatch.py groupstart <project>  # start all services of the group
python3 scripts/devwatch.py groupstop  <project>  # stop only the running ones of the group
```
