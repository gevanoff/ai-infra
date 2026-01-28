#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "$*" >&2
}

SERVICE_USER="${SDXL_TURBO_USER:-sdxlturbo}"
SERVICE_HOME="${SDXL_TURBO_HOME:-/var/lib/sdxl-turbo}"
ENV_FILE="/etc/sdxl-turbo/sdxl-turbo.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../sdxl_turbo_server.py"
ENV_TEMPLATE="${HERE}/../env/sdxl-turbo.env.example"

ensure_runtime() {
  if [[ ! -d "$SERVICE_HOME" ]]; then
    echo "ERROR: ${SERVICE_HOME} not found. Run install.sh first." >&2
    exit 1
  fi
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: sdxl_turbo_server.py not found at ${SHIM_SRC}" >&2
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
  sudo chown root:root "$ENV_FILE"
  sudo chmod 644 "$ENV_FILE"
  note "Installed env template to ${ENV_FILE}"
}

sync_shim() {
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/sdxl_turbo_server.py"
  if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/sdxl_turbo_server.py"
  fi
  sudo chmod 644 "${SERVICE_HOME}/sdxl_turbo_server.py"
}

ensure_runtime
sync_env_file
sync_shim

if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl restart sdxl-turbo.service
  exit 0
fi

note "ERROR: systemctl not found; cannot restart sdxl-turbo service."
exit 1
