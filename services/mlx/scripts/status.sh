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
sudo launchctl print system/"$LABEL" | sed -n '1,220p'

echo "---- listen 10240 ----" >&2
if command -v lsof >/dev/null 2>&1; then
  sudo lsof -nP -iTCP:10240 -sTCP:LISTEN 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -an | grep '\.10240 ' || true
fi

if [[ -f /var/log/mlx/mlx-openai.err.log ]]; then
  echo "---- tail /var/log/mlx/mlx-openai.err.log ----" >&2
  sudo tail -n 60 /var/log/mlx/mlx-openai.err.log >&2 || true
fi
