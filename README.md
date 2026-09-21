# DevWatch

Projektbezogener Dienst-Manager als **Omarchy-Bar-Widget**: lokale Dev-Dienste
(Docker Compose, systemd-user, Custom-Befehle) gruppiert nach Projekt, mit
Start/Stop/Neustart direkt aus der Leiste.

> **Voraussetzung:** Omarchy (Quickshell-basierte Shell). DevWatch ist ein
> Omarchy-Plugin und läuft nur dort — nicht auf GNOME/KDE/XFCE. Davon abgesehen
> ist es auf jedem Linux mit Omarchy lauffähig.

## Installation

```bash
omarchy plugin add https://github.com/SeBoOne/omarchy-devwatch.git --enable
```

Entwicklung: in `~/Projects/devwatch/` editieren, dann die geänderten Dateien
nach `~/.config/omarchy/plugins/sebo.devwatch/` kopieren (Hot-Reload aktiv).

**Firewall-Unterstützung (optional):** Die Funktion `"firewall": true` (siehe
unten) nutzt `ufw`. Omarchy bringt ufw nicht als Pflichtbestandteil mit; ob es
installiert ist, prüfst du mit `which ufw`. Fehlt es, installierst du es:

```bash
sudo pacman -S ufw   # bzw. das Paket deiner Distribution
```

## Dienste deklarieren

Eine `.devservices.json` im Projektordner (z.B. `~/Projects/<projekt>/`):

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

- `compose`: `docker compose up -d` / `stop` im Projektordner, optional `file`
  und `service_name` für einen einzelnen Container.
- `systemd`: `systemctl --user start/stop <unit>`.
- `cmd`: Befehl in eigener Session, PID + Logdatei im Projekt
  (`.devwatch-<name>.log`). Stop mit SIGTERM, verifiziert PID-Identität
  (/proc start time) vor dem Kill, ESCalation zu SIGKILL nach 6 s.
- `port`: optionaler TCP-Check (IPv4 + IPv6) als Health-Anzeige.
- `firewall`: optionales Feld (greift nur wenn `port` gesetzt). Beim Start wird
  `sudo -n ufw allow <port>` ausgeführt, beim Stop `sudo -n ufw delete allow
  <port>`. Benötigt eine NOPASSWD-Sudo-Regel (siehe
  `scripts/setup-ufw-sudoers.sh`). Bei fehlender Berechtigung meldet der Status
  einen echten Firewall-Fehler (`allowed: false`); der Dienst startet/stoppt
  trotzdem, das Backend bricht NICHT ab.

## Gruppierung

Eine `.devservices.json` mit **>1 Dienst** wird im Panel zu **EINER Gruppe**
(ein Schalter statt Einzeldienst-Zeilen). Mit **==1 Dienst** bleibt sie ein
Einzel-Schalter. Eine Mehrfach-Datei lässt sich per `"group": false` von der
Gruppierung ausnehmen (bleibt Einzeldienste).

Gruppenname: `"group": {"name": "..."}` oder Top-Level `"group_name"`,
Fallback ist der Projekt-Key (Ordnername):

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

Gruppen-Schalter im Panel: **1× Linksklick** startet alle Dienste der Gruppe
(keiner läuft), **2×-Klick-Flow** stoppt alle aktiven. **Rechtsklick** öffnet
die Unteransicht (Drill-Down) mit den einzelnen Diensten der Gruppe (Start/Stop
wie gewohnt) plus „← zurück" zur Übersicht.

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
python3 scripts/devwatch.py groupstart <projekt>  # startet alle Dienste der Gruppe
python3 scripts/devwatch.py groupstop  <projekt>  # stoppt nur die laufenden der Gruppe
```
