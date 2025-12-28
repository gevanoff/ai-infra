#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

echo "Installing all services..." >&2

"${ROOT}/ollama/scripts/install.sh"
"${ROOT}/mlx/scripts/install.sh"
"${ROOT}/gateway/scripts/install.sh"

echo "Done." >&2
