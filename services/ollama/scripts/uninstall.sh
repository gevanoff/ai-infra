#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  LABEL="com.ollama.server"
  DST="/Library/LaunchDaemons/${LABEL}.plist"
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo rm -f "$DST"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now ollama >/dev/null 2>&1 || true
    echo "✓ ollama service disabled/stopped (systemd)" >&2
    echo "NOTE: This script does not remove the ollama binary or data directories." >&2
    echo "Hint: remove manually if desired." >&2
    exit 0
  fi
  echo "ERROR: systemctl not found; cannot uninstall/disable ollama service." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
