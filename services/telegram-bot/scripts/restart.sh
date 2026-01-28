#!/usr/bin/env bash
set -euo pipefail

LABEL="telegram-bot"
OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$EUID" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ "$OS" == "Darwin" ]]; then
  LABEL_LAUNCHD="com.telegram-bot.server"
  echo "Restarting ${LABEL_LAUNCHD}..."
  sudo launchctl kickstart -k system/"${LABEL_LAUNCHD}" || true
  sudo launchctl print system/"${LABEL_LAUNCHD}" | sed -n '1,120p' || true
  exit 0
fi

echo "Restarting ${LABEL}..."
systemctl restart "${LABEL}.service"
sleep 1
systemctl status "${LABEL}.service" --no-pager
