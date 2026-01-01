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

LOG_DIR="/var/log/gateway"
LOG_FILE="${LOG_DIR}/post_deploy_hook.log"

# Post-deploy hook:
# - Freeze a timestamped release manifest
# - Run the appliance smoketest against the running service

tmp="$(mktemp 2>/dev/null || echo "/tmp/post_deploy_hook.$$")"

{
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "=== post_deploy_hook start ${ts} ==="
  echo "user=$(id -un 2>/dev/null || echo unknown) cwd=$(pwd)"
  echo "script_dir=${HERE}"
  echo

  "${HERE}/freeze_release.sh"
  echo
  "${HERE}/appliance_smoketest.sh"
} >"${tmp}" 2>&1

rc=$?
echo "" >>"${tmp}" || true
echo "=== post_deploy_hook end rc=${rc} ===" >>"${tmp}" || true

sudo mkdir -p "${LOG_DIR}" || true
sudo touch "${LOG_FILE}" || true
sudo chown gateway:staff "${LOG_FILE}" || true
sudo chmod 640 "${LOG_FILE}" || true

sudo -u gateway -H tee -a "${LOG_FILE}" <"${tmp}" >/dev/null || true
rm -f "${tmp}" || true

exit ${rc}
