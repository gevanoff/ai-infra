#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat restart is macOS-only." >&2
  exit 1
fi

LABEL_APP="com.ai.librechat"
LABEL_MONGO="com.ai.librechat.mongodb"

sudo launchctl kickstart -k system/"$LABEL_MONGO" 2>/dev/null || true
sudo launchctl kickstart -k system/"$LABEL_APP" 2>/dev/null || true
