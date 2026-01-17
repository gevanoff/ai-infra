#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: mlx launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl

LABEL="com.mlx.openai.server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

# If the job isn't loaded, try to bootstrap it (common after fresh machine setup).
if ! sudo launchctl print system/"$LABEL" >/dev/null 2>&1; then
  if [[ -f "$PLIST" ]]; then
    sudo launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
  fi
fi

sudo launchctl kickstart -k system/"$LABEL" || {
  echo "ERROR: failed to kickstart ${LABEL}" >&2
  if [[ -f /var/log/mlx/mlx-openai.err.log ]]; then
    echo "---- tail /var/log/mlx/mlx-openai.err.log ----" >&2
    sudo tail -n 60 /var/log/mlx/mlx-openai.err.log >&2 || true
  fi
  exit 1
}
