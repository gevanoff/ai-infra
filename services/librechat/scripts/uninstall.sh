#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat uninstall is macOS-only." >&2
  exit 1
fi

LABEL_APP="com.ai.librechat"
LABEL_MONGO="com.ai.librechat.mongodb"
PLIST_APP="/Library/LaunchDaemons/${LABEL_APP}.plist"
PLIST_MONGO="/Library/LaunchDaemons/${LABEL_MONGO}.plist"
PF_ANCHOR="/etc/pf.anchors/com.ai.librechat"
PF_CONF="/etc/pf.conf"

PURGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data)
      PURGE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

sudo launchctl bootout system/"$LABEL_APP" 2>/dev/null || true
sudo launchctl bootout system/"$LABEL_MONGO" 2>/dev/null || true

sudo rm -f "$PLIST_APP" "$PLIST_MONGO"

if [[ -f "$PF_ANCHOR" ]]; then
  sudo rm -f "$PF_ANCHOR"
fi

# Remove pf.conf anchor lines (idempotent)
if sudo grep -q 'com.ai.librechat' "$PF_CONF"; then
  sudo sed -i '' '/com\.ai\.librechat/d' "$PF_CONF"
  sudo pfctl -f "$PF_CONF" >/dev/null || true
fi

if [[ "$PURGE" == "true" ]]; then
  sudo rm -rf /var/lib/librechat /var/log/librechat
fi

echo "Uninstalled." >&2
