#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

SERVICE_USER="${LUXTTS_USER:-luxtts}"
SERVICE_HOME="${LUXTTS_HOME:-/var/lib/luxtts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../lux_tts_server.py"

if [[ ! -f "$SHIM_SRC" ]]; then
  note "ERROR: lux_tts_server.py not found at ${SHIM_SRC}"
  exit 1
fi

sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/lux_tts_server.py"
if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/lux_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/lux_tts_server.py"
fi
sudo chmod 644 "${SERVICE_HOME}/lux_tts_server.py"

if [[ -d "${SERVICE_HOME}/app/.git" ]]; then
  sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
fi

note "Deploy complete."
