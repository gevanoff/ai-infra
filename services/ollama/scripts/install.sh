#!/bin/zsh
set -euo pipefail

LABEL="com.ollama.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"

# Runtime dirs (only if your plist/env uses them)
sudo mkdir -p /var/lib/ollama/{run,cache} /var/log/ollama
sudo chown -R ollama:staff /var/lib/ollama /var/log/ollama
sudo chmod 750 /var/lib/ollama /var/log/ollama

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"
sudo plutil -lint "$DST" >/dev/null

# Reload service
sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$DST"
sudo launchctl kickstart -k system/"$LABEL"
