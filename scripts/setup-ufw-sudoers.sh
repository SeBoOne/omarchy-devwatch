#!/usr/bin/env bash
# setup-ufw-sudoers.sh — NOPASSWD-Sudo für ufw einrichten (VORLAGE, nur vorbereitet)
#
# Ansatz: devwatch.py ruft für Dienste mit "firewall": true
#   sudo -n ufw allow  <port>      (beim Start, vor Prozessstart)
#   sudo -n ufw delete allow <port>(beim Stop, NACH Prozessende)
# auf. Damit das ohne Passwort-Abfrage funktioniert (die Omarchy-Bar kann kein
# Passwort eingeben), braucht devwatch eine schmale NOPASSWD-Regel NUR für ufw.
#
# >>> DIESES SKRIPT WIRD NICHT VOM AGENTEN AUSGEFÜHRT <<<
# Es ist eine VORLAGE für den Operator (Sebo / root). Es benötigt ROOT-Rechte
# (visudo/sudoers-Schreiben) und wird deshalb manuell ausgeführt:
#   sudo bash scripts/setup-ufw-sudoers.sh
#
# WICHTIG — SICHERHEIT:
# * Es wird NIEMALS ein allgemeines "ALL=(ALL) NOPASSWD: ALL" angelegt.
# * Die Regel ist auf den einzigen Befehl /usr/sbin/ufw beschränkt.
# * Der Pfad /usr/sbin/ufw ist hart kodiert (kein shell-star, kein Komma),
#   damit die Regel nicht per Argument-Injection ausweitbar ist.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/devwatch-ufw"
# Der exakte Eintrag — NICHT verallgemeinern. Ohne COMMAND-Argumente erlaubt
# diese Zeile nur "ufw" samt seiner Argumente, nicht sudo mit beliebigen Befehlen.
# Der Nutzername wird dynamisch ermittelt (User, der `sudo bash ...` ausführt),
# damit das Skript auf jedem System funktioniert.
if [[ -z "${SUDO_USER:-}" ]]; then
  echo "Fehler: Konnte den Ziel-Benutzer nicht ermitteln (SUDO_USER leer)." >&2
  exit 1
fi
SUDOERS_LINE="${SUDO_USER} ALL=(root) NOPASSWD: /usr/sbin/ufw"

# Nur mit ausreichender Berechtigung weiter — das Skript MUSS als root laufen
# (visudo/sudoers.d schreiben). Verweigert, wenn der Aufrufer kein root ist.
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Fehler: Dieses Setup-Skript benötigt ROOT-Rechte." >&2
  echo "Führe es aus mit:  sudo bash $0" >&2
  exit 1
fi

# Validierung NACH eventuellem Eintrag, aber SCHRITTWEISE: nur den echten
# Befehl pruefen, der gelingen kann. "sudo -n ufw status" schlägt ohne aktive
# Regel/hinzugefügte Befehle fehl? Nein — ufw status braucht nur die Sudo-Regel.
# Deshalb hier eine reine Status-Abfrage als Funktions-Check der Regel.

echo "Geplante sudoers-Regel:"
echo "  ${SUDOERS_LINE}"
echo

# Sicherheitshinweis: Das Ziel ist eine MINIMALE Regel. Falls der Nutzername
# abweicht oder ein anderer Command-Pfad gilt, hier entspr. anpassen (visudo).
# Niemals Wildcards an den Command-Pfad hängen.
echo "Bitte prüfen und ggf. anpassen. Dann mit:"
echo "  sudo visudo -f ${SUDOERS_FILE}"
echo "anlegen und mit:"
echo "  sudo visudo -c"
echo "validieren."
echo

echo "Hinweise:"
echo " 1. Diese Regel erlaubt NOPASSWD AUSSCHLIESSLICH für/usr/sbin/ufw."
echo " 2. ops-wise keine anderen Befehle in diese Datei aufnehmen."
echo " 3. Nach dem Anlegen kann devwatch zum Testen ausführen:"
echo "    sudo -n ufw status"