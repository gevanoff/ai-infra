#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

echo "==== ollama ===="
"${ROOT}/ollama/scripts/status.sh"

echo "\n==== mlx ===="
"${ROOT}/mlx/scripts/status.sh"

echo "\n==== gateway ===="
"${ROOT}/gateway/scripts/status.sh"
