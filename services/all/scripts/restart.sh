#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

echo "Restarting all services..." >&2

"${ROOT}/ollama/scripts/restart.sh"
"${ROOT}/mlx/scripts/restart.sh"
"${ROOT}/gateway/scripts/restart.sh"

echo "Done." >&2
