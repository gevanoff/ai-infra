#!/usr/bin/env bash
set -euo pipefail

LABEL="telegram-bot"
OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$EUID" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ "$OS" == "Darwin" ]]; then
  LABEL_LAUNCHD="com.telegram-bot.server"
  echo "=== ${LABEL_LAUNCHD} launchd status ==="
  launchctl print system/"${LABEL_LAUNCHD}" | sed -n '1,120p' || true
  echo ""
  echo "=== Process check ==="
  ps aux | grep telegram_gateway_bot.js | grep -v grep || true
  echo ""
  echo "=== Recent logs ==="
  if [[ -f /var/log/telegram-bot/telegram-bot.err.log ]]; then
    ls -l /var/log/telegram-bot/telegram-bot.err.log
    tail -n 50 /var/log/telegram-bot/telegram-bot.err.log
  fi
  exit 0
fi

echo "=== ${LABEL} service status ==="
systemctl status "${LABEL}.service" --no-pager || true
echo ""
echo "=== Recent logs ==="
journalctl -u "${LABEL}.service" -n 20 --no-pager
