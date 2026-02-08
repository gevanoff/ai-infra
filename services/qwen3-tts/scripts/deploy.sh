#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

SERVICE_USER="${QWEN3_TTS_USER:-qwen3tts}"
SERVICE_HOME="${QWEN3_TTS_HOME:-/var/lib/qwen3-tts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../qwen3_tts_server.py"
RUN_SCRIPT_SRC="${HERE}/run_qwen3_tts.py"
OS="$(uname -s 2>/dev/null || echo unknown)"
LABEL="com.qwen3-tts.server"
PLIST_SRC="${HERE}/../launchd/${LABEL}.plist.example"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ ! -f "$SHIM_SRC" ]]; then
  note "ERROR: qwen3_tts_server.py not found at ${SHIM_SRC}"
  exit 1
fi

sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/qwen3_tts_server.py"
if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/qwen3_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/qwen3_tts_server.py"
fi
sudo chmod 644 "${SERVICE_HOME}/qwen3_tts_server.py"

if [[ -f "$RUN_SCRIPT_SRC" ]]; then
  sudo mkdir -p "${SERVICE_HOME}/app/scripts"
  sudo cp -f "$RUN_SCRIPT_SRC" "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
  sudo chmod 755 "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
fi

if [[ -d "${SERVICE_HOME}/app/.git" ]]; then
  sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
fi

if [[ "$OS" == "Darwin" ]]; then
  if [[ -f "$PLIST_SRC" ]]; then
    sudo sed "s/<string>qwen3tts<\/string>/<string>${SERVICE_USER}<\/string>/" "$PLIST_SRC" | sudo tee "$PLIST_DST" >/dev/null
    sudo chown root:wheel "$PLIST_DST" 2>/dev/null || sudo chown root:root "$PLIST_DST"
    sudo chmod 644 "$PLIST_DST"
    sudo plutil -lint "$PLIST_DST" >/dev/null
    sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
    sudo launchctl bootstrap system "$PLIST_DST"
    sudo launchctl kickstart -k system/"$LABEL"
  else
    note "WARN: missing launchd plist at ${PLIST_SRC}"
  fi
fi

note "Deploy complete."
