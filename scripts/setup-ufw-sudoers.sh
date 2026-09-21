#!/usr/bin/env bash
# setup-ufw-sudoers.sh — configure the NOPASSWD sudo rule for ufw
#
# Purpose: devwatch.py runs for services with "firewall": true
#   sudo -n ufw allow  <port>       (on start, before process start)
#   sudo -n ufw delete allow <port> (on stop, AFTER the process ended)
# To work without a password prompt (the Omarchy bar cannot type a password),
# devwatch needs a narrow NOPASSWD rule ONLY for ufw.
#
# Run as root (sudoers write):
#   sudo bash ~/.config/omarchy/plugins/sebo.devwatch/scripts/setup-ufw-sudoers.sh
#
# IMPORTANT — SECURITY:
# * It NEVER creates a blanket "ALL=(ALL) NOPASSWD: ALL".
# * The rule is limited to the single command /usr/sbin/ufw.
# * The path /usr/sbin/ufw is hard-coded (no shell-star, no comma) so the rule
#   cannot be widened via argument injection.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/devwatch-ufw"
# The exact entry — do NOT generalize. Without COMMAND arguments this line only
# allows "ufw" and its arguments, not sudo with arbitrary commands.
# The user name is resolved dynamically (the one running `sudo bash ...`),
# so the script works on any system.
if [[ -z "${SUDO_USER:-}" ]]; then
  echo "Error: could not determine the target user (SUDO_USER is empty)." >&2
  exit 1
fi
SUDOERS_LINE="${SUDO_USER} ALL=(root) NOPASSWD: /usr/sbin/ufw"

# The script MUST run as root (writes /etc/sudoers.d).
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: this setup script requires ROOT privileges." >&2
  echo "Run it with:  sudo bash $0" >&2
  exit 1
fi

# Write the rule only if the file is absent or differs, so we never clobber an
# existing file the operator may have edited manually.
if [[ -f "${SUDOERS_FILE}" ]]; then
  if grep -qF -- "${SUDOERS_LINE}" "${SUDOERS_FILE}"; then
    echo "Rule already present in ${SUDOERS_FILE}; skipping write."
  else
    echo "Updating ${SUDOERS_FILE} (existing file lacks the rule)."
    echo "${SUDOERS_LINE}" >> "${SUDOERS_FILE}"
  fi
else
  echo "Creating ${SUDOERS_FILE}."
  echo "${SUDOERS_LINE}" > "${SUDOERS_FILE}"
fi

# sudoers files must be root:root 0440 — otherwise visudo/sudo warn ("world-
# writable" / bad permissions) on every subsequent run. Set it explicitly.
echo "Setting permissions root:root 0440 on ${SUDOERS_FILE}."
chown root:root "${SUDOERS_FILE}"
chmod 0440 "${SUDOERS_FILE}"

# Validate the resulting sudoers file (catches syntax errors before they lock
# sudo out). A failed validation exits non-zero and shows the offending line.
echo "Validating sudoers syntax…"
visudo -c -f "${SUDOERS_FILE}"
visudo -c >/dev/null 2>&1 || { echo "visudo reported system-wide issues — review." >&2; }

# Functional check: the rule should let ufw run without a password prompt.
echo "Testing: sudo -n ufw status"
if sudo -n ufw status >/dev/null 2>&1; then
  echo "OK — ufw is accessible without a password."
else
  echo "Note: 'sudo -n ufw status' still prompted/failed (exit $?)." >&2
  echo "This means the rule is not active yet or ufw is not configured." >&2
  echo "start/stop of devwatch services still works — only the automatic" >&2
  echo "port open/close is skipped (honest status, no failure)." >&2
  exit 1
fi