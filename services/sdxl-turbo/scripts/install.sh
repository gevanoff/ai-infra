#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

note() {
  echo "$*" >&2
}

if [[ $# -gt 0 ]]; then
  note "ERROR: this per-role installer does not accept arguments: $*"
  note "Hint: use services/all/scripts/install.sh --host <host> for remote installs."
  exit 2
fi

OS="$(uname -s 2>/dev/null || echo unknown)"
SERVICE_NAME="sdxl-turbo"
SERVICE_USER="${SDXL_TURBO_USER:-sdxlturbo}"
SERVICE_HOME="${SDXL_TURBO_HOME:-/var/lib/sdxl-turbo}"
VENV_PATH="${SERVICE_HOME}/venv"
ENV_FILE="/etc/sdxl-turbo/sdxl-turbo.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../sdxl_turbo_server.py"
ENV_TEMPLATE="${HERE}/../env/sdxl-turbo.env.example"

install_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    note "Env file already exists at ${ENV_FILE}"
    return 0
  fi
  sudo mkdir -p "$(dirname "$ENV_FILE")"
  sudo cp "$ENV_TEMPLATE" "$ENV_FILE"
  sudo chown root:root "$ENV_FILE"
  sudo chmod 644 "$ENV_FILE"
}

install_shim() {
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: sdxl_turbo_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/sdxl_turbo_server.py"
  sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/sdxl_turbo_server.py"
  sudo chmod 644 "${SERVICE_HOME}/sdxl_turbo_server.py"
}

install_python_deps() {
  local torch_pkg
  torch_pkg="${SDXL_TURBO_TORCH_PIP:-torch}"

  if [[ -n "${SDXL_TURBO_TORCH_INDEX_URL:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install "$torch_pkg" --index-url "${SDXL_TURBO_TORCH_INDEX_URL}"
  else
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install "$torch_pkg"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install \
    fastapi "uvicorn[standard]" diffusers transformers accelerate safetensors pillow

  if [[ -n "${SDXL_TURBO_PIP_EXTRA:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install ${SDXL_TURBO_PIP_EXTRA}
  fi
}

if [[ "$OS" == "Linux" ]]; then
  require_cmd systemctl

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
      note "NOTE: this installer targets Ubuntu 22.04; detected ${ID:-unknown} ${VERSION_ID:-unknown}."
    fi
  fi

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    sudo useradd --system --create-home --home-dir "${SERVICE_HOME}" --shell /bin/bash "${SERVICE_USER}"
  fi

  sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/sdxl-turbo
  sudo chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}" /var/log/sdxl-turbo
  sudo chmod 750 "${SERVICE_HOME}" /var/log/sdxl-turbo

  PYTHON_BIN="${SDXL_TURBO_PYTHON_BIN:-}"
  if [[ -z "$PYTHON_BIN" ]]; then
    if command -v python3.10 >/dev/null 2>&1; then
      PYTHON_BIN="python3.10"
    else
      PYTHON_BIN="python3"
    fi
  fi

  if command -v apt-get >/dev/null 2>&1; then
    sudo -E env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    sudo -E env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential git ca-certificates curl "$PYTHON_BIN" "${PYTHON_BIN}-venv" "${PYTHON_BIN}-dev" >/dev/null 2>&1
  fi

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${SERVICE_USER}" -H "$PYTHON_BIN" -m venv "$VENV_PATH"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  install_python_deps
  install_env_file
  install_shim

  SERVICE_UNIT_SRC="${HERE}/../systemd/sdxl-turbo.service"
  SERVICE_UNIT_DST="/etc/systemd/system/sdxl-turbo.service"
  sudo cp "$SERVICE_UNIT_SRC" "$SERVICE_UNIT_DST"
  sudo chmod 644 "$SERVICE_UNIT_DST"

  sudo systemctl daemon-reload
  sudo systemctl enable --now sdxl-turbo.service
  exit 0
fi

note "ERROR: unsupported OS or missing systemctl."
exit 1
