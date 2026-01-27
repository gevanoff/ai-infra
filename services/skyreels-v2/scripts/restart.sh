#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  sudo launchctl kickstart -k system/com.skyreels-v2.server
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl restart skyreels-v2.service
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
