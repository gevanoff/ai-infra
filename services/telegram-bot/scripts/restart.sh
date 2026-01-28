#!/usr/bin/env bash
set -euo pipefail

LABEL="telegram-bot"

if [[ "$EUID" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

echo "Restarting ${LABEL}..."
systemctl restart "${LABEL}.service"
sleep 1
systemctl status "${LABEL}.service" --no-pager
