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

  # First attempt.
  if sudo launchctl bootstrap system "$plist" >/dev/null 2>&1; then
    return 0
  fi

  # If it raced and is now loaded, continue.
  if sudo launchctl print system/"$label" >/dev/null 2>&1; then
    return 0
  fi

  # Common failure mode: "Bootstrap failed: 5: Input/output error" when a stale
  # job instance exists or launchd rejects the prior state. Do a best-effort
  # bootout and retry once.
  echo "WARN: bootstrap failed for ${label}; attempting bootout + retry..." >&2
  sudo launchctl bootout system/"$label" 2>/dev/null || true
  sudo launchctl bootout system "$plist" 2>/dev/null || true

  if sudo launchctl bootstrap system "$plist" >/dev/null 2>&1; then
    return 0
  fi

  # Final check; if still not loaded, fail with a helpful hint.
  if sudo launchctl print system/"$label" >/dev/null 2>&1; then
    return 0
  fi

  echo "ERROR: unable to bootstrap ${label} from ${plist}" >&2
  echo "Hint: run services/librechat/scripts/refresh_wrappers.sh (node/mongod wrapper perms)" >&2
  echo "Hint: see launchd logs: sudo log show --last 2m --predicate 'process == \"launchd\"' --style compact | tail -n 120" >&2
  return 1
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
