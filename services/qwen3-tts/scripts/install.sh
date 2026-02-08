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
SERVICE_USER="${QWEN3_TTS_USER:-qwen3tts}"
SERVICE_HOME="${QWEN3_TTS_HOME:-/var/lib/qwen3-tts}"
VENV_PATH="${SERVICE_HOME}/venv"
ENV_FILE="/etc/qwen3-tts/qwen3-tts.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../qwen3_tts_server.py"
ENV_TEMPLATE="${HERE}/../env/qwen3-tts.env.example"
REPO_URL_DEFAULT="https://github.com/QwenLM/Qwen3-TTS"

install_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    note "Env file already exists at ${ENV_FILE}"
    return 0
  fi
  sudo mkdir -p "$(dirname "$ENV_FILE")"
  sudo cp "$ENV_TEMPLATE" "$ENV_FILE"
  sudo chown root:wheel "$ENV_FILE" 2>/dev/null || sudo chown root:root "$ENV_FILE"
  sudo chmod 644 "$ENV_FILE"
}

install_shim() {
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: qwen3_tts_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/qwen3_tts_server.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/qwen3_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/qwen3_tts_server.py"
  sudo chmod 644 "${SERVICE_HOME}/qwen3_tts_server.py"

  if [[ -f "${HERE}/run_qwen3_tts.py" ]]; then
    sudo mkdir -p "${SERVICE_HOME}/app/scripts"
    sudo cp -f "${HERE}/run_qwen3_tts.py" "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
    sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
    sudo chmod 755 "${SERVICE_HOME}/app/scripts/run_qwen3_tts.py"
  fi
}

clone_repo() {
  local repo_url
  repo_url="${QWEN3_TTS_REPO_URL:-$REPO_URL_DEFAULT}"
  if [[ -z "$repo_url" ]]; then
    return 0
  fi
  if [[ ! -d "${SERVICE_HOME}/app/.git" ]]; then
    sudo -u "${SERVICE_USER}" -H git clone "$repo_url" "${SERVICE_HOME}/app" || true
  else
    sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
  fi
}

install_requirements() {
  local req_file="${SERVICE_HOME}/app/requirements.txt"
  if [[ -f "$req_file" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install -r "$req_file" || true
  fi
  if [[ -n "${QWEN3_TTS_PIP_EXTRA:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install ${QWEN3_TTS_PIP_EXTRA}
  fi
}

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil
  require_cmd python3

  LABEL="com.qwen3-tts.server"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"

  sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/qwen3-tts

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    note "Creating system user '${SERVICE_USER}'..."
    next_uid=501
    while id -u "$next_uid" >/dev/null 2>&1; do
      ((next_uid++))
    done
    sudo dscl . -create /Users/"${SERVICE_USER}"
    sudo dscl . -create /Users/"${SERVICE_USER}" UserShell /bin/bash
    sudo dscl . -create /Users/"${SERVICE_USER}" RealName "Qwen3-TTS Service User"
    sudo dscl . -create /Users/"${SERVICE_USER}" UniqueID "$next_uid"
    sudo dscl . -create /Users/"${SERVICE_USER}" PrimaryGroupID 20
    sudo dscl . -create /Users/"${SERVICE_USER}" NFSHomeDirectory "${SERVICE_HOME}"
    sudo createhomedir -u "${SERVICE_USER}" -c 2>/dev/null || true
  fi

  sudo chown -R "${SERVICE_USER}":staff "${SERVICE_HOME}" /var/log/qwen3-tts
  sudo chmod 750 "${SERVICE_HOME}" /var/log/qwen3-tts

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${SERVICE_USER}" -H python3 -m venv "$VENV_PATH"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" httpx

  clone_repo
  install_requirements
  install_env_file
  install_shim

  sudo sed "s/<string>qwen3tts<\/string>/<string>${SERVICE_USER}<\/string>/" "$SRC" | sudo tee "$DST" >/dev/null
  sudo chown root:wheel "$DST" 2>/dev/null || sudo chown root:root "$DST"
  sudo chmod 644 "$DST"
  sudo plutil -lint "$DST" >/dev/null

  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$DST"
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
      sudo useradd --system --create-home --home-dir "${SERVICE_HOME}" --shell /bin/bash "${SERVICE_USER}"
    fi

    sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/qwen3-tts
    sudo chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}" /var/log/qwen3-tts
    sudo chmod 750 "${SERVICE_HOME}" /var/log/qwen3-tts

    PYTHON_BIN="${QWEN3_TTS_PYTHON_BIN:-}"
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
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" httpx

    clone_repo
    install_requirements
    install_env_file
    install_shim

    SERVICE_UNIT_SRC="${HERE}/../systemd/qwen3-tts.service"
    SERVICE_UNIT_DST="/etc/systemd/system/qwen3-tts.service"
    sudo cp "$SERVICE_UNIT_SRC" "$SERVICE_UNIT_DST"
    sudo chmod 644 "$SERVICE_UNIT_DST"

    sudo systemctl daemon-reload
    sudo systemctl enable --now qwen3-tts.service
    exit 0
  fi
fi

note "ERROR: unsupported OS or missing systemctl/launchctl."
exit 1
