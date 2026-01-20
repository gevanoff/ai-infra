#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: heartmula launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl

LABEL="com.heartmula.server"
DST="/Library/LaunchDaemons/${LABEL}.plist"

sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo rm -f "$DST"
