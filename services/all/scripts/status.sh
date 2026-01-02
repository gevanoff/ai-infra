#!/bin/zsh
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This script targets macOS (launchd)." >&2
  echo "Hint: run it on the Mac host that runs launchd." >&2
  exit 1
fi

require_cmd launchctl

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

echo "==== ollama ===="
"${ROOT}/ollama/scripts/status.sh"

echo "\n==== mlx ===="
"${ROOT}/mlx/scripts/status.sh"

echo "\n==== gateway ===="
"${ROOT}/gateway/scripts/status.sh"
