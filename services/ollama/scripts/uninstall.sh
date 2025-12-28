#!/bin/zsh
set -euo pipefail

LABEL="com.ollama.server"
DST="/Library/LaunchDaemons/${LABEL}.plist"

sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo rm -f "$DST"
