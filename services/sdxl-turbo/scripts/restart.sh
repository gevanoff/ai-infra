#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="sdxl-turbo"

note() {
  echo "[$SERVICE_NAME] $*" >&2
}

case "$(uname -s)" in
  Darwin)
    plist="/Library/LaunchDaemons/com.${SERVICE_NAME}.plist"
    if [[ -f "$plist" ]]; then
      sudo launchctl unload "$plist" >/dev/null 2>&1 || true
      sudo launchctl load "$plist"
      note "Restarted launchd service com.${SERVICE_NAME}"
    else
      note "ERROR: launchd plist not found at ${plist}"
      exit 1
    fi
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl restart "${SERVICE_NAME}.service"
      note "Restarted systemd service ${SERVICE_NAME}"
    else
      note "ERROR: systemctl not found"
      exit 1
    fi
    ;;
  *)
    note "ERROR: unsupported OS for restart.sh"
    exit 1
    ;;
esac
