#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat status is macOS-only." >&2
  exit 1
fi

LABEL_APP="com.ai.librechat"
LABEL_MONGO="com.ai.librechat.mongodb"
PORT="${LIBRECHAT_PORT:-3080}"

echo "== launchd ==" >&2
sudo launchctl print system/"$LABEL_MONGO" 2>/dev/null || true
sudo launchctl print system/"$LABEL_APP" 2>/dev/null || true

echo "== listeners ==" >&2
sudo lsof -nP -iTCP:27017 -sTCP:LISTEN || true
sudo lsof -nP -iTCP:${PORT} -sTCP:LISTEN || true

echo "== logs (tail) ==" >&2
sudo tail -n 60 /var/log/librechat/mongodb.err.log 2>/dev/null || true
sudo tail -n 60 /var/log/librechat/librechat.err.log 2>/dev/null || true
sudo tail -n 40 /var/log/librechat/librechat.out.log 2>/dev/null || true

if sudo tail -n 200 /var/log/librechat/librechat.err.log 2>/dev/null | grep -q "Cannot find module '/var/lib/librechat/bin/node "; then
  echo "HINT: Your /var/lib/librechat/bin/node wrapper is malformed. Fix with:" >&2
  echo "  services/librechat/scripts/refresh_wrappers.sh" >&2
fi
