#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat verify is macOS-only." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 2
  }
}

require_cmd curl
require_cmd lsof

PORT="${LIBRECHAT_PORT:-3080}"

echo "Checking MongoDB listener..." >&2
lsof -nP -iTCP:27017 -sTCP:LISTEN >/dev/null

echo "Checking LibreChat /health..." >&2
curl -fsS "http://127.0.0.1:${PORT}/health" | grep -q "OK"

echo "OK" >&2
