#!/usr/bin/env bash
# setup-ufw-sudoers.sh — NOPASSWD sudo for ufw (TEMPLATE, not auto-executed)
#
# Approach: devwatch.py runs for services with "firewall": true
#   sudo -n ufw allow  <port>       (on start, before process start)
#   sudo -n ufw delete allow <port> (on stop, AFTER the process ended)
# To work without a password prompt (the Omarchy bar cannot type a password),
# devwatch needs a narrow NOPASSWD rule ONLY for ufw.
#
# >>> THIS SCRIPT IS NOT EXECUTED BY THE AGENT <<<
# It is a template for the operator (root). It needs ROOT privileges
# (visudo/sudoers write) and is therefore run manually:
#   sudo bash scripts/setup-ufw-sudoers.sh
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

# Only continue with sufficient privileges — the script MUST run as root
# (writes visudo/sudoers.d). Refuses if the caller is not root.
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: this setup script requires ROOT privileges." >&2
  echo "Run it with:  sudo bash $0" >&2
  exit 1
fi

# Validation after the entry, but stepwise: only check the real command that can
# succeed. `sudo -n ufw status` only needs the sudo rule, so a plain status
# query works as a functional check of the rule.

echo "Planned sudoers rule:"
echo "  ${SUDOERS_LINE}"
echo

# Security note: the goal is a MINIMAL rule. If the user name differs or a
# different command path applies, adjust accordingly (visudo).
# Never append wildcards to the command path.
echo "Review and adjust if needed, then create it with:"
echo "  sudo visudo -f ${SUDOERS_FILE}"
echo "and validate with:"
echo "  sudo visudo -c"
echo

echo "Notes:"
echo " 1. This rule allows NOPASSWD EXCLUSIVELY for /usr/sbin/ufw."
echo " 2. Do not add other commands to this file."
echo " 3. After creating it, devwatch can be tested with:"
echo "    sudo -n ufw status"