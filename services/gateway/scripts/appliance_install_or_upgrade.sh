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
  echo "ERROR: This script targets macOS (appliance host)." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# Idempotent wrapper:
# - install.sh is safe to rerun (creates runtime dirs/venv/plist, seeds .env if missing)
# - deploy.sh is safe to rerun (rsyncs code, restarts service, waits for local HTTP /health)
# - freeze_release.sh writes a timestamped manifest
# - appliance_smoketest.sh validates chat stream + embeddings + tool + replay

"${HERE}/install.sh"
"${HERE}/deploy.sh"
"${HERE}/freeze_release.sh"
"${HERE}/appliance_smoketest.sh"

echo "OK: appliance install/upgrade complete"
