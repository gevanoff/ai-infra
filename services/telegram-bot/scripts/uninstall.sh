#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this script must run as root (sudo not found)." >&2
    exit 1
  fi
  exec sudo bash "$0" "$@"
fi

LABEL="telegram-bot"
SERVICE_DST="/etc/systemd/system/${LABEL}.service"
RUNTIME_DIR="/var/lib/telegram-bot"
LOG_DIR="/var/log/telegram-bot"
BOT_USER="${BOT_USER:-telegram-bot}"

echo "[1/5] Stopping and disabling service..."
if systemctl is-active --quiet "${LABEL}.service"; then
  systemctl stop "${LABEL}.service"
  echo "  Service stopped."
fi

if systemctl is-enabled --quiet "${LABEL}.service" 2>/dev/null; then
  systemctl disable "${LABEL}.service"
  echo "  Service disabled."
fi

echo "[2/5] Removing systemd service file..."
if [[ -f "${SERVICE_DST}" ]]; then
  rm -v "${SERVICE_DST}"
  systemctl daemon-reload
  echo "  Service file removed."
fi

echo "[3/5] Removing runtime directories..."
if [[ -d "${RUNTIME_DIR}" ]]; then
  echo "  WARNING: This will delete all data in ${RUNTIME_DIR}"
  read -p "  Continue? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "${RUNTIME_DIR}"
    echo "  Removed ${RUNTIME_DIR}"
  else
    echo "  Skipped removing ${RUNTIME_DIR}"
  fi
fi

if [[ -d "${LOG_DIR}" ]]; then
  rm -rf "${LOG_DIR}"
  echo "  Removed ${LOG_DIR}"
fi

echo "[4/5] Removing user..."
if id "${BOT_USER}" >/dev/null 2>&1; then
  userdel "${BOT_USER}"
  echo "  Removed user: ${BOT_USER}"
fi

echo "[5/5] Cleanup complete!"
echo ""
echo "The ${LABEL} service has been uninstalled."
echo ""
