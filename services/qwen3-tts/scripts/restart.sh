#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl kickstart -k system/com.qwen3-tts.server
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl restart qwen3-tts.service
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
