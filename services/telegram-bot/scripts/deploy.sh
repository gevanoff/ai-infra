#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  echo "ERROR: Telegram Bot deploy script is Linux-only (systemd)." >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this script must run as root (sudo not found)." >&2
    exit 1
  fi
  exec sudo bash "$0" "$@"
fi

LABEL="telegram-bot"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/var/lib/telegram-bot/app"
BOT_USER="${BOT_USER:-telegram-bot}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "ERROR: ${APP_DIR} does not exist. Run install.sh first." >&2
  exit 1
fi

echo "[1/3] Copying bot code to ${APP_DIR}..."
cp -v "${HERE}/../telegram_gateway_bot.js" "${APP_DIR}/"
cp -v "${HERE}/../package.json" "${APP_DIR}/"
chown -R "${BOT_USER}:${BOT_USER}" "${APP_DIR}"

echo "[2/3] Installing/updating Node.js dependencies..."
cd "${APP_DIR}"
if sudo -u "${BOT_USER}" npm install --production; then
  echo "  Dependencies installed successfully."
else
  echo "  WARNING: npm install failed."
  exit 1
fi

echo "[3/3] Restarting service..."
systemctl restart "${LABEL}.service"
sleep 2

if systemctl is-active --quiet "${LABEL}.service"; then
  echo ""
  echo "Deployment successful! Service is running."
  echo "Check status: sudo systemctl status ${LABEL}"
else
  echo ""
  echo "WARNING: Service failed to start. Check logs:"
  echo "  sudo journalctl -u ${LABEL} -n 50"
  exit 1
fi
