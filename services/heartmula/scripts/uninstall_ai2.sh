#!/usr/bin/env bash
set -euo pipefail

# Uninstall HeartMula from a macOS host (ai2)
# - Unloads and removes launchd plist (/Library/LaunchDaemons/com.heartmula.server.plist)
# - Removes runtime dir (/var/lib/heartmula) and logs (/var/log/heartmula)
# - Removes the heartmula system user if present
# Idempotent and safe; use --yes to skip confirmation

HEARTMULA_USER=${HEARTMULA_USER:-heartmula}
LAUNCHD_PLIST=${LAUNCHD_PLIST:-/Library/LaunchDaemons/com.heartmula.server.plist}
VARDIR=${VARDIR:-/var/lib/heartmula}
LOGDIR=${LOGDIR:-/var/log/heartmula}
FORCE=${1:-}

function ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (sudo)."
    exit 1
  fi
}

function confirm() {
  if [ "${FORCE}" = "--yes" ] || [ "${FORCE}" = "-y" ]; then
    return 0
  fi
  echo "This will permanently remove HeartMula runtime, logs, plist, and the '$HEARTMULA_USER' system user (if present)."
  read -r -p "Continue? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

function unload_and_remove_plist() {
  if [ -f "$LAUNCHD_PLIST" ]; then
    echo "Attempting to unload launchd plist: $LAUNCHD_PLIST"
    # Use bootout/bootstrap for modern macOS where available
    launchctl bootout system "$LAUNCHD_PLIST" >/dev/null 2>&1 || true
    launchctl unload "$LAUNCHD_PLIST" >/dev/null 2>&1 || true
    rm -f "$LAUNCHD_PLIST"
    echo "Removed plist: $LAUNCHD_PLIST"
  else
    echo "No plist found at $LAUNCHD_PLIST (skipping)"
  fi
}

function remove_runtime_dirs() {
  if [ -d "$VARDIR" ]; then
    echo "Removing $VARDIR"
    rm -rf "$VARDIR"
  else
    echo "$VARDIR not present (skipping)"
  fi

  if [ -d "$LOGDIR" ]; then
    echo "Removing $LOGDIR"
    rm -rf "$LOGDIR"
  else
    echo "$LOGDIR not present (skipping)"
  fi
}

function remove_system_user() {
  if id -u "$HEARTMULA_USER" >/dev/null 2>&1; then
    echo "Removing system user: $HEARTMULA_USER"
    if command -v sysadminctl >/dev/null 2>&1; then
      # sysadminctl may prompt; use it where available
      sysadminctl -deleteUser "$HEARTMULA_USER" || true
    fi
    # Fallback to dscl
    if dscl . -list /Users | grep -q "^$HEARTMULA_USER$"; then
      dscl . -delete "/Users/$HEARTMULA_USER" || true
    fi
    echo "User removal attempted (verify on your system)"
  else
    echo "User $HEARTMULA_USER not found (skipping)"
  fi
}

function cleanup_misc() {
  # Remove systemd/launchd remnants in other places (defensive)
  if [ -f "/etc/heartmula/heartmula.env" ]; then
    rm -f /etc/heartmula/heartmula.env || true
  fi
}

function main() {
  ensure_root
  confirm
  unload_and_remove_plist
  remove_runtime_dirs
  remove_system_user
  cleanup_misc
  echo "Uninstall complete. If you want to preserve model checkpoints, make sure you backed up $VARDIR/ckpt before running this script."
}

main "$@"
