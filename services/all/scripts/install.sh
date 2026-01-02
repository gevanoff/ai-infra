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
require_cmd plutil

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

echo "Installing all services..." >&2

"${ROOT}/ollama/scripts/install.sh"
"${ROOT}/mlx/scripts/install.sh"
"${ROOT}/gateway/scripts/install.sh"

echo "Done." >&2
