#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

confirm() {
  local force="${1:-}"
  if [ "$force" = "--yes" ] || [ "$force" = "-y" ]; then
    return 0
  fi
  echo "This will remove the HeartMula systemd unit, runtime files, and logs."
  read -r -p "Continue? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

main() {
  local force="${1:-}"
  ensure_root
  confirm "$force"

  require_cmd systemctl

  SERVICE="com.heartmula.server.service"
  SERVICE_FILE="/etc/systemd/system/${SERVICE}"
  VARDIR="${HEARTMULA_HOME:-/var/lib/heartmula}"
  LOGDIR="/var/log/heartmula"
  ENV_FILE="/etc/heartmula/heartmula.env"

  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true

  if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
  fi

  if [ -d "$VARDIR" ]; then
    rm -rf "$VARDIR"
  fi

  if [ -d "$LOGDIR" ]; then
    rm -rf "$LOGDIR"
  fi

  if [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
  fi

  echo "Uninstall complete."
}

main "${1:-}"
