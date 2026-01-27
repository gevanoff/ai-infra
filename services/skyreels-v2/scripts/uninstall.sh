#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl bootout system/com.skyreels-v2.server 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.skyreels-v2.server.plist
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl disable --now skyreels-v2.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/skyreels-v2.service
  sudo systemctl daemon-reload
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
