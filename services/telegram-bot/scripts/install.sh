#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  echo "ERROR: Telegram Bot install script is Linux-only (systemd)." >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this installer must run as root (sudo not found)." >&2
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

require_cmd systemctl
require_cmd node
require_cmd npm
require_cmd id

LABEL="telegram-bot"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICE_SRC="${HERE}/../systemd/${LABEL}.service"
SERVICE_DST="/etc/systemd/system/${LABEL}.service"
ENV_EXAMPLE="${HERE}/../env/telegram-bot.env.example"
ENV_DST="/var/lib/telegram-bot/telegram-bot.env"
APP_DIR="/var/lib/telegram-bot/app"
RUNTIME_DIR="/var/lib/telegram-bot"
LOG_DIR="/var/log/telegram-bot"
BOT_USER="${BOT_USER:-telegram-bot}"

echo "[1/6] Creating user and directories..."
if ! id "${BOT_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${BOT_USER}"
  echo "  Created user: ${BOT_USER}"
else
  echo "  User ${BOT_USER} already exists."
fi

mkdir -p "${RUNTIME_DIR}" "${APP_DIR}" "${LOG_DIR}"
chown -R "${BOT_USER}:${BOT_USER}" "${RUNTIME_DIR}" "${LOG_DIR}"
echo "  Created directories: ${RUNTIME_DIR}, ${APP_DIR}, ${LOG_DIR}"

echo "[2/6] Copying systemd service..."
cp -v "${SERVICE_SRC}" "${SERVICE_DST}"
systemctl daemon-reload
echo "  Service installed: ${SERVICE_DST}"

echo "[3/6] Creating env file (if needed)..."
if [[ ! -f "${ENV_DST}" ]]; then
  cp -v "${ENV_EXAMPLE}" "${ENV_DST}"
  chown "${BOT_USER}:${BOT_USER}" "${ENV_DST}"
  chmod 600 "${ENV_DST}"
  echo ""
  echo "  ⚠️  IMPORTANT: Edit ${ENV_DST} with your Telegram token and Gateway bearer token!"
  echo ""
else
  echo "  Env file already exists: ${ENV_DST}"
fi

echo "[4/6] Copying bot code..."
cp -v "${HERE}/../telegram_gateway_bot.js" "${APP_DIR}/"
cp -v "${HERE}/../package.json" "${APP_DIR}/"
chown -R "${BOT_USER}:${BOT_USER}" "${APP_DIR}"
echo "  Bot code copied to ${APP_DIR}"

echo "[5/6] Installing Node.js dependencies..."
cd "${APP_DIR}"
if sudo -u "${BOT_USER}" npm install --production; then
  echo "  Dependencies installed successfully."
else
  echo "  WARNING: npm install failed. You may need to install dependencies manually."
fi

echo "[6/6] Enabling systemd service..."
systemctl enable "${LABEL}.service"
echo "  Service enabled: ${LABEL}.service"

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit ${ENV_DST} with your tokens"
echo "  2. Start the bot: sudo systemctl start ${LABEL}"
echo "  3. Check status: sudo systemctl status ${LABEL}"
echo "  4. View logs: sudo journalctl -u ${LABEL} -f"
echo ""
