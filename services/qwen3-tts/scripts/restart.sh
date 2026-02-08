#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this restart script must run as root (sudo not found)." >&2
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

if [[ "$OS" == "Darwin" ]]; then
  LABEL="com.qwen3-tts.server"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  if [[ ! -f "$PLIST" ]]; then
    echo "Missing ${PLIST}. Run services/qwen3-tts/scripts/install.sh first." >&2
    exit 1
  fi
  launchctl bootout system/"$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap system "$PLIST"; then
    if launchctl print system/"$LABEL" >/dev/null 2>&1; then
      echo "WARN: launchctl bootstrap failed for ${LABEL}, but job is already loaded; continuing." >&2
    else
      echo "ERROR: launchctl bootstrap failed for ${LABEL}." >&2
      exit 1
    fi
  fi
  launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl restart qwen3-tts.service
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
