#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl bootout system/com.personaplex.server 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.personaplex.server.plist
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl disable --now personaplex.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/personaplex.service
  sudo systemctl daemon-reload
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
