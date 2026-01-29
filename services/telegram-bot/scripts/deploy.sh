#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

OS="$(uname -s 2>/dev/null || echo unknown)"

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

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd node
  require_cmd npm

  LABEL_LAUNCHD="com.telegram-bot.server"
  PLIST="/Library/LaunchDaemons/${LABEL_LAUNCHD}.plist"

  if [[ ! -d "${APP_DIR}" ]]; then
    echo "ERROR: ${APP_DIR} does not exist. Run install.sh first." >&2
    exit 1
  fi

  echo "[1/3] Copying bot code to ${APP_DIR}..."
  cp -v "${HERE}/../telegram_gateway_bot.js" "${APP_DIR}/"
  cp -v "${HERE}/../package.json" "${APP_DIR}/"
  chown -R "${BOT_USER}":staff "${APP_DIR}"

  echo "[2/3] Installing/updating Node.js dependencies..."
  cd "${APP_DIR}"
  if sudo -u "${BOT_USER}" -H env HOME="/var/lib/telegram-bot" npm_config_cache="/var/lib/telegram-bot/.npm" npm install --production; then
    echo "  Dependencies installed successfully."
    sudo -u "${BOT_USER}" -H env HOME="/var/lib/telegram-bot" npm_config_cache="/var/lib/telegram-bot/.npm" npm audit fix --omit=dev || true
  else
    echo "  WARNING: npm install failed."
    exit 1
  fi

  echo "[3/3] Restarting launchd service..."
  if [[ -f "${PLIST}" ]]; then
    sudo launchctl kickstart -k system/"${LABEL_LAUNCHD}" || sudo launchctl bootstrap system "${PLIST}"
  else
    echo "WARNING: Launchd plist not found at ${PLIST}." >&2
  fi
  exit 0
fi

if [[ "$OS" != "Linux" ]]; then
  echo "ERROR: Telegram Bot deploy script supports Linux (systemd) and macOS (launchd) only." >&2
  exit 1
fi

require_cmd systemctl
require_cmd node
require_cmd npm

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
  sudo -u "${BOT_USER}" npm audit fix --omit=dev || true
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
