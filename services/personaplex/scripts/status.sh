#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="$(basename "$(dirname "$(dirname "$0")")")"
OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  label="com.${SERVICE_NAME}.server"
  sudo launchctl print system/"$label" | sed -n '1,220p'
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  sudo systemctl status --no-pager "${SERVICE_NAME}.service" || true
  exit 0
fi

echo "Unsupported OS" >&2
exit 1
