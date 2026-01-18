#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat restart is macOS-only." >&2
  exit 1
fi

LABEL_APP="com.ai.librechat"
LABEL_MONGO="com.ai.librechat.mongodb"

PLIST_APP="/Library/LaunchDaemons/${LABEL_APP}.plist"
PLIST_MONGO="/Library/LaunchDaemons/${LABEL_MONGO}.plist"

ensure_loaded() {
  local label="$1"
  local plist="$2"

  if sudo launchctl print system/"$label" >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "$plist" ]]; then
    echo "ERROR: missing plist: ${plist}" >&2
    return 1
  fi

  echo "Bootstrapping ${label}..." >&2
  if ! sudo launchctl bootstrap system "$plist"; then
    # If it raced and is now loaded, continue.
    sudo launchctl print system/"$label" >/dev/null 2>&1
  fi
}

ensure_loaded "$LABEL_MONGO" "$PLIST_MONGO"
sudo launchctl kickstart -k system/"$LABEL_MONGO" 2>/dev/null || true

# Only attempt to start LibreChat if it has been deployed.
if [[ -f "/var/lib/librechat/app/api/server/index.js" ]]; then
  ensure_loaded "$LABEL_APP" "$PLIST_APP"
  sudo launchctl kickstart -k system/"$LABEL_APP" 2>/dev/null || true
else
  echo "NOTE: LibreChat app not deployed yet; not starting ${LABEL_APP}." >&2
fi
