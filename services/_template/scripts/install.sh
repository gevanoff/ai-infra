#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="SERVICE_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LAUNCHD_TEMPLATE="${SERVICE_DIR}/launchd/com.service.plist.example"
SYSTEMD_TEMPLATE="${SERVICE_DIR}/systemd/service.service.example"

note() {
  echo "[$SERVICE_NAME] $*" >&2
}

install_launchd() {
  local plist_dst="/Library/LaunchDaemons/com.${SERVICE_NAME}.plist"
  sudo cp "$LAUNCHD_TEMPLATE" "$plist_dst"
  sudo launchctl unload "$plist_dst" >/dev/null 2>&1 || true
  sudo launchctl load "$plist_dst"
  note "Installed launchd plist at ${plist_dst}"
}

install_systemd() {
  local unit_dst="/etc/systemd/system/${SERVICE_NAME}.service"
  sudo cp "$SYSTEMD_TEMPLATE" "$unit_dst"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SERVICE_NAME}.service" || true
  note "Installed systemd unit at ${unit_dst}"
}

"${SCRIPT_DIR}/configure.sh"

case "$(uname -s)" in
  Darwin)
    install_launchd
    ;;
  Linux)
    install_systemd
    ;;
  *)
    note "ERROR: unsupported OS for install.sh"
    exit 1
    ;;
esac
