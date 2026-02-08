#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this uninstall script must run as root (sudo not found)." >&2
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

if [[ "$OS" == "Darwin" ]]; then
  launchctl bootout system/com.qwen3-tts.server 2>/dev/null || true
  rm -f /Library/LaunchDaemons/com.qwen3-tts.server.plist
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl disable --now qwen3-tts.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/qwen3-tts.service
  sudo systemctl daemon-reload
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
