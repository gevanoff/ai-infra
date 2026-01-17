#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: mlx launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl

LABEL="com.mlx.openai.server"
sudo launchctl kickstart -k system/"$LABEL"
