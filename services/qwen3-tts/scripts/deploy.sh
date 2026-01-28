#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

SERVICE_USER="${QWEN3_TTS_USER:-qwen3tts}"
SERVICE_HOME="${QWEN3_TTS_HOME:-/var/lib/qwen3-tts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../qwen3_tts_server.py"

if [[ ! -f "$SHIM_SRC" ]]; then
  note "ERROR: qwen3_tts_server.py not found at ${SHIM_SRC}"
  exit 1
fi

sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/qwen3_tts_server.py"
if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/qwen3_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/qwen3_tts_server.py"
fi
sudo chmod 644 "${SERVICE_HOME}/qwen3_tts_server.py"

if [[ -d "${SERVICE_HOME}/app/.git" ]]; then
  sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
fi

note "Deploy complete."
