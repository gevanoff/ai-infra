#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl bootout system/com.vibevoice-asr.server 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.vibevoice-asr.server.plist
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl disable --now vibevoice-asr.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/vibevoice-asr.service
  sudo systemctl daemon-reload
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
