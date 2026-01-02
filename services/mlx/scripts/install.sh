#!/bin/zsh
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This script targets macOS (launchd)." >&2
  echo "Hint: run it on the Mac host that runs launchd." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil

LABEL="com.mlx.openai.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
MLX_USER="${MLX_USER:-mlx}"

# Runtime dirs expected by the plist/env
sudo mkdir -p /var/lib/mlx/{cache,run} /var/log/mlx

if ! id -u "${MLX_USER}" >/dev/null 2>&1; then
  echo "ERROR: user '${MLX_USER}' does not exist on this machine" >&2
  echo "Hint: create it (or set MLX_USER / update the plist UserName and chown targets)." >&2
  exit 1
fi

sudo chown -R "${MLX_USER}":staff /var/lib/mlx /var/log/mlx
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
