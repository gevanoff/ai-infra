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

validate_wrapper() {
  local path="$1"
  # Expect:
  #   #!/bin/sh
  #   exec "/abs/path" "$@"
  local line
  line="$(sudo sed -n '2p' "$path" 2>/dev/null | tr -d '\r' || true)"
  # NOTE: keep the regex in a single-quoted variable so "$@" is treated literally
  # (and doesn't expand to this script's arguments).
  local re
  re='^exec "\/[^"[:space:]]+" "\$@"$'
  if [[ "$line" =~ $re ]]; then
    return 0
  fi
  return 1
}

if ! validate_wrapper /var/lib/librechat/bin/node; then
  echo "HINT: /var/lib/librechat/bin/node wrapper looks malformed. Fix with:" >&2
  echo "  services/librechat/scripts/refresh_wrappers.sh" >&2
  echo "Diag: wrapper line 2:" >&2
  sudo sed -n '1,3p' /var/lib/librechat/bin/node 2>/dev/null | sed 's/^/  /' >&2 || true
fi
