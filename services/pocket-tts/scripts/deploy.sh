#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

OS="$(uname -s 2>/dev/null || echo unknown)"
POCKET_TTS_USER="${POCKET_TTS_USER:-pockettts}"
POCKET_TTS_HOME="${POCKET_TTS_HOME:-/var/lib/pocket-tts}"
ENV_FILE="/etc/pocket-tts/pocket-tts.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../pocket_tts_server.py"
ENV_TEMPLATE="${HERE}/../env/pocket-tts.env.example"

ensure_runtime() {
  if [[ ! -d "$POCKET_TTS_HOME" ]]; then
    echo "ERROR: ${POCKET_TTS_HOME} not found. Run install.sh first." >&2
    exit 1
  fi
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: pocket_tts_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
}

sync_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    note "Env file already exists at ${ENV_FILE}; leaving as-is."
    return 0
  fi
  sudo mkdir -p "$(dirname "$ENV_FILE")"
  sudo cp "$ENV_TEMPLATE" "$ENV_FILE"
  sudo chown root:wheel "$ENV_FILE"
  sudo chmod 644 "$ENV_FILE"
  note "Installed env template to ${ENV_FILE}"
}

sync_shim() {
  sudo cp -f "$SHIM_SRC" "${POCKET_TTS_HOME}/pocket_tts_server.py"
  sudo chown "${POCKET_TTS_USER}":staff "${POCKET_TTS_HOME}/pocket_tts_server.py"
  sudo chmod 644 "${POCKET_TTS_HOME}/pocket_tts_server.py"
}

if [[ "$OS" == "Darwin" ]]; then
  LABEL="com.pocket-tts.server"
  ensure_runtime
  sync_env_file
  sync_shim
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    ensure_runtime
    sync_env_file
    sync_shim
    sudo systemctl restart pocket-tts
    exit 0
  fi
  echo "ERROR: systemctl not found; cannot deploy pocket-tts as a service." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
