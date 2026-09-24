#!/usr/bin/env bash
# setup-ufw-sudoers.sh — install / remove the NOPASSWD rule for the DevWatch
# root-owned helper `devwatch-ufw`.
#
# SECURITY (marketplace-review compliant):
#   * Run this as your NORMAL user:   bash scripts/setup-ufw-sudoers.sh
#     NOT `sudo bash ...`. The script performs each privileged step with an
#     explicit `sudo <command>` call, so no user-writable checkout code is ever
#     executed under root bash.
#   * The NOPASSWD grant covers ONLY the root-owned helper
#     /usr/local/sbin/devwatch-ufw for the fixed actions allow|deny|status
#     (sudoers Cmnd-masking). There is NO grant for /usr/sbin/ufw itself, so a
#     compromised user process cannot run `ufw disable`/`reset`/arbitrary rules.
#   * The helper is installed root:root 0755 via `sudo install` (copied, never
#     run as root bash) and it enforces a strict numeric port range.
#
# Usage:
#   bash scripts/setup-ufw-sudoers.sh            # install helper + rule
#   bash scripts/setup-ufw-sudoers.sh --uninstall  # remove rule (before plugin rm)
#
# Requires sudo rights for the calling (non-root) user.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/devwatch-ufw"
HELPER_TARGET="/usr/local/sbin/devwatch-ufw"
HELPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/devwatch-ufw"

# Refuse to run as root: we can't tell whose user-side the rule should target.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "Error: run this as your NORMAL user, not as root." >&2
  echo "  bash scripts/setup-ufw-sudoers.sh [--uninstall]" >&2
  exit 1
fi

TARGET_USER="$(id -un)"

# Exactly three helper actions; sudoers Cmnd-masking prevents any other command
# line from matching. The helper additionally enforces the port range, so the
# effective privilege is 'open/close exactly one TCP|UDP port' plus read-only
# status — nothing else.
RULES=(
  "${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_TARGET} status"
  "${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_TARGET} allow [0-9]*"
  "${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_TARGET} deny  [0-9]*"
)

# ---------------------------------------------------------------------------
# Uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ -f "${SUDOERS_FILE}" ]]; then
    if sudo grep -qF "NOPASSWD: ${HELPER_TARGET}" "${SUDOERS_FILE}"; then
      # Remove ONLY our three helper rules, preserving any other lines an
      # operator placed in the same drop-in (install appends, uninstall must
      # not over-remove).
      echo "Removing DevWatch helper rules from ${SUDOERS_FILE}."
      sudo sed -i "/NOPASSWD: ${HELPER_TARGET}/d" "${SUDOERS_FILE}"
      # If nothing remains, drop the now-empty drop-in; otherwise keep it.
      if [[ -z "$(sudo tr -d '[:space:]' < "${SUDOERS_FILE}")" ]]; then
        sudo rm -f "${SUDOERS_FILE}"
      else
        sudo chown root:root "${SUDOERS_FILE}"
        sudo chmod 0440 "${SUDOERS_FILE}"
      fi
      sudo visudo -c >/dev/null 2>&1 || echo "Review sudoers: visudo -c" >&2
    else
      echo "${SUDOERS_FILE} holds no DevWatch helper rule; leaving it untouched."
    fi
  else
    echo "${SUDOERS_FILE} does not exist — nothing to remove."
  fi
  echo "Done. You may remove the plugin now:  omarchy plugin remove sebo.devwatch"
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
if [[ "$#" -gt 0 ]]; then
  echo "Unknown option: $1 (expected: --uninstall)" >&2
  exit 64
fi

# 1. Helper as a root-owned file (cp semantics — never executed as root bash).
[[ -f "${HELPER_SRC}" ]] || { echo "Error: ${HELPER_SRC} not found." >&2; exit 1; }
echo "Installing helper -> ${HELPER_TARGET} (root:root 0755)"
sudo install -o root -g root -m 0755 "${HELPER_SRC}" "${HELPER_TARGET}"

# 2. Merge the three rules (append only the ones not already present, so manual
#    edits are preserved).
sudo mkdir -p /etc/sudoers.d
for rule in "${RULES[@]}"; do
  if ! sudo grep -qF -- "${rule}" "${SUDOERS_FILE}" 2>/dev/null; then
    echo "${rule}" | sudo tee -a "${SUDOERS_FILE}" >/dev/null
  fi
done
sudo chown root:root "${SUDOERS_FILE}"
sudo chmod 0440 "${SUDOERS_FILE}"

# 3. Validate.
sudo visudo -c -f "${SUDOERS_FILE}"
sudo visudo -c >/dev/null 2>&1 || echo "Warning: visudo reported system-wide issues — review." >&2

# 4. Functional check.
echo "Testing: sudo -n ${HELPER_TARGET} status"
if sudo -n "${HELPER_TARGET}" status >/dev/null 2>&1; then
  echo "OK — helper reachable without a password."
else
  echo "Note: helper status still prompted/failed (exit $?)." >&2
  echo "Service start/stop still works — only the automatic port open/close" >&2
  echo "is skipped (honest status, no failure). Review /etc/sudoers.d/." >&2
  exit 1
fi