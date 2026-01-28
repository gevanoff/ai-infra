#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"
SERVICE_HOME="${LIGHTON_OCR_HOME:-/var/lib/lighton-ocr}"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl bootout system/com.lighton-ocr.server 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.lighton-ocr.server.plist
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl disable --now lighton-ocr.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/lighton-ocr.service
  sudo systemctl daemon-reload
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
