#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="SERVICE_NAME"

note() {
  echo "[$SERVICE_NAME] $*" >&2
}

case "$(uname -s)" in
  Darwin)
    plist="/Library/LaunchDaemons/com.${SERVICE_NAME}.plist"
    if [[ -f "$plist" ]]; then
      sudo launchctl unload "$plist" >/dev/null 2>&1 || true
      sudo rm -f "$plist"
      note "Removed launchd plist ${plist}"
    else
      note "Launchd plist not found at ${plist}"
    fi
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
      sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      sudo systemctl daemon-reload
      note "Removed systemd unit ${SERVICE_NAME}.service"
    else
      note "ERROR: systemctl not found"
      exit 1
    fi
    ;;
  *)
    note "ERROR: unsupported OS for uninstall.sh"
    exit 1
    ;;
esac
