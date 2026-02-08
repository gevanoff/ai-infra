#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  LABEL="com.qwen3-tts.server"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  if [[ ! -f "$PLIST" ]]; then
    echo "Missing ${PLIST}. Run services/qwen3-tts/scripts/install.sh first." >&2
    exit 1
  fi
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl restart qwen3-tts.service
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
