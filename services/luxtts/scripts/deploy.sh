#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    note "ERROR: this deploy script must run as root (sudo not found)."
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

SERVICE_USER="${LUXTTS_USER:-luxtts}"
SERVICE_HOME="${LUXTTS_HOME:-/var/lib/luxtts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../lux_tts_server.py"
RUN_SCRIPT_SRC="${HERE}/run_luxtts.py"
OS="$(uname -s 2>/dev/null || echo unknown)"
LABEL="com.luxtts.server"
PLIST_SRC="${HERE}/../launchd/${LABEL}.plist.example"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ ! -f "$SHIM_SRC" ]]; then
  note "ERROR: lux_tts_server.py not found at ${SHIM_SRC}"
  exit 1
fi

sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/lux_tts_server.py"
if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/lux_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/lux_tts_server.py"
fi
sudo chmod 644 "${SERVICE_HOME}/lux_tts_server.py"

if [[ -f "$RUN_SCRIPT_SRC" ]]; then
  sudo mkdir -p "${SERVICE_HOME}/app/scripts"
  sudo cp -f "$RUN_SCRIPT_SRC" "${SERVICE_HOME}/app/scripts/run_luxtts.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/app/scripts/run_luxtts.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/app/scripts/run_luxtts.py"
  sudo chmod 755 "${SERVICE_HOME}/app/scripts/run_luxtts.py"
fi

if [[ -d "${SERVICE_HOME}/app/.git" ]]; then
  sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
fi

if [[ "$OS" == "Darwin" ]]; then
  if [[ -f "$PLIST_SRC" ]]; then
    sudo sed "s/<string>luxtts<\/string>/<string>${SERVICE_USER}<\/string>/" "$PLIST_SRC" | sudo tee "$PLIST_DST" >/dev/null
    sudo chown root:wheel "$PLIST_DST" 2>/dev/null || sudo chown root:root "$PLIST_DST"
    sudo chmod 644 "$PLIST_DST"
    plutil -lint "$PLIST_DST" >/dev/null
    launchctl bootout system/"$LABEL" 2>/dev/null || true
    if ! launchctl bootstrap system "$PLIST_DST"; then
      if launchctl print system/"$LABEL" >/dev/null 2>&1; then
        note "WARN: launchctl bootstrap failed for ${LABEL}, but job is already loaded; continuing."
      else
        note "ERROR: launchctl bootstrap failed for ${LABEL}."
        exit 1
      fi
    fi
    launchctl kickstart -k system/"$LABEL"
  else
    note "WARN: missing launchd plist at ${PLIST_SRC}"
  fi
fi

note "Deploy complete."
