#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd uname

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This hook targets macOS (appliance host)." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# Post-deploy hook:
# - Freeze a timestamped release manifest
# - Run the appliance smoketest against the running service

"${HERE}/freeze_release.sh"
"${HERE}/appliance_smoketest.sh"
