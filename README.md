# DevWatch

Projektbezogener Dienst-Manager als Omarchy-Bar-Widget: lokale Dev-Dienste
(Docker Compose, systemd-user, Custom-Befehle) gruppiert nach Projekt, mit
Start/Stop/Neustart direkt aus der Leiste.

## Installation

```bash
cp -r devwatch ~/.config/omarchy/plugins/sebo.devwatch
omarchy-shell shell rescanPlugins
omarchy plugin enable sebo.devwatch --section right
```

Entwicklung: in `~/Projects/devwatch/` editieren, dann die geänderten Dateien
nach `~/.config/omarchy/plugins/sebo.devwatch/` kopieren (Hot-Reload aktiv).

## Dienste deklarieren

Eine `.devservices.json` im Projektordner (z.B. `~/Projects/<projekt>/`):

```json
{
  "services": [
    {"name": "db",  "type": "compose", "file": "docker-compose.yml"},
    {"name": "api", "type": "systemd", "unit": "myapp.service"},
    {"name": "web", "type": "cmd", "command": "php -S localhost:8080 -t public",
     "cwd": ".", "port": 8080, "pidfile": ".devwatch-web.pid"}
  ]
}
```

- `compose`: `docker compose up -d` / `stop` im Projektordner, optional `file`
  und `service_name` für einen einzelnen Container.
- `systemd`: `systemctl --user start/stop <unit>`.
- `cmd`: Befehl in eigener Session, PID + Logdatei im Projekt
  (`.devwatch-<name>.log`). Stop mit SIGTERM, verifiziert PID-Identität
  (/proc start time) vor dem Kill, ESCalation zu SIGKILL nach 6 s.
- `port`: optionaler TCP-Check (IPv4 + IPv6) als Health-Anzeige.

Zusätzliche Scan-Pfade (Default nur `~/Projects/`):
`~/.config/devwatch/config.json` → `{"scan_paths": ["/abs/pfad"]}`

## UI

- Bar-Widget rechts (grün, wenn mind. ein Dienst läuft), Klick öffnet Panel.
- Ein Klick auf laufenden Dienst = Stoppen anfordern (Confirm), nochmal
  klicken = Stoppen. Gestoppter Dienst: Klick = Starten.
- Tastatur: ↑/↓ navigieren, Enter = Start/Stop(Confirm), Esc = schließen.

## Backend (CLI)

```bash
python3 scripts/devwatch.py status                 # JSON-Snapshot
python3 scripts/devwatch.py start <projekt> <dienst>
python3 scripts/devwatch.py stop  <projekt> <dienst>
python3 scripts/devwatch.py restart <projekt> <dienst>
```
