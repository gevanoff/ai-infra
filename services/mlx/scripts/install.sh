#!/bin/zsh
set -euo pipefail

LABEL="com.mlx.openai.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"

# Runtime dirs expected by the plist/env
sudo mkdir -p /var/lib/mlx/{cache,run} /var/log/mlx
sudo chown -R mlx:staff /var/lib/mlx /var/log/mlx
sudo chmod 750 /var/lib/mlx /var/log/mlx

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

# Validate plist parses as XML property list
sudo plutil -lint "$DST" >/dev/null

# Reload service
sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$DST"
sudo launchctl kickstart -k system/"$LABEL"
