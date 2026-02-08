#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  LABEL="com.luxtts.server"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  if [[ ! -f "$PLIST" ]]; then
    echo "Missing ${PLIST}. Run services/luxtts/scripts/install.sh first." >&2
    exit 1
  fi
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl restart luxtts.service
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
