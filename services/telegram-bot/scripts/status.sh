#!/usr/bin/env bash
set -euo pipefail

LABEL="telegram-bot"

if [[ "$EUID" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

echo "=== ${LABEL} service status ==="
systemctl status "${LABEL}.service" --no-pager || true
echo ""
echo "=== Recent logs ==="
journalctl -u "${LABEL}.service" -n 20 --no-pager
