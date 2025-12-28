#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${HERE}/../models/manifest.txt"

if ! command -v ollama >/dev/null 2>&1; then
	echo "ERROR: ollama not found in PATH" >&2
	exit 1
fi

if [[ ! -f "${MANIFEST}" ]]; then
	echo "ERROR: manifest not found: ${MANIFEST}" >&2
	exit 1
fi

grep -vE '^\s*#|^\s*$' "${MANIFEST}" | while read -r m; do
	ollama pull "$m"
done
