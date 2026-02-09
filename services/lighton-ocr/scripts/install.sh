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
SERVICE_NAME="lighton-ocr"
SERVICE_USER="${LIGHTON_OCR_USER:-lightonocr}"
SERVICE_HOME="${LIGHTON_OCR_HOME:-/var/lib/lighton-ocr}"
VENV_PATH="${SERVICE_HOME}/venv"
ENV_FILE="/etc/lighton-ocr/lighton-ocr.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../lighton_ocr_server.py"
ENV_TEMPLATE="${HERE}/../env/lighton-ocr.env.example"
REQ_FILE="${HERE}/../requirements.txt"
RUNNER_SRC="${HERE}/../scripts/run_lighton_ocr.py"
REPO_URL_DEFAULT="https://huggingface.co/lightonai/LightOnOCR-2-1B"

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
    echo "ERROR: lighton_ocr_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/lighton_ocr_server.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/lighton_ocr_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/lighton_ocr_server.py"
  sudo chmod 644 "${SERVICE_HOME}/lighton_ocr_server.py"
}

install_requirements_file() {
  if [[ ! -f "$REQ_FILE" ]]; then
    note "WARN: pinned requirements not found at ${REQ_FILE}"
    return 0
  fi
  sudo cp -f "$REQ_FILE" "${SERVICE_HOME}/requirements.txt"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/requirements.txt" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/requirements.txt"
  sudo chmod 644 "${SERVICE_HOME}/requirements.txt"
}

install_runner() {
  if [[ ! -f "$RUNNER_SRC" ]]; then
    note "WARN: runner not found at ${RUNNER_SRC}"
    return 0
  fi
  sudo mkdir -p "${SERVICE_HOME}/app/scripts"
  sudo cp -f "$RUNNER_SRC" "${SERVICE_HOME}/app/scripts/run_lighton_ocr.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/app/scripts/run_lighton_ocr.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/app/scripts/run_lighton_ocr.py"
  sudo chmod 755 "${SERVICE_HOME}/app/scripts/run_lighton_ocr.py"
}

clone_repo() {
  local repo_url
  repo_url="${LIGHTON_OCR_REPO_URL:-$REPO_URL_DEFAULT}"
  if [[ -z "$repo_url" ]]; then
    return 0
  fi
  if [[ ! -d "${SERVICE_HOME}/app/.git" ]]; then
    sudo -u "${SERVICE_USER}" -H git clone "$repo_url" "${SERVICE_HOME}/app" || true
  else
    sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
  fi
}

ensure_git_lfs() {
  if command -v git-lfs >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo -E env DEBIAN_FRONTEND=noninteractive apt-get install -y git-lfs >/dev/null 2>&1 || true
    if command -v git-lfs >/dev/null 2>&1; then
      git lfs install >/dev/null 2>&1 || true
      return 0
    fi
  fi
  note "NOTE: git-lfs not installed; HuggingFace repos may require it."
}

install_requirements() {
  if [[ -f "${SERVICE_HOME}/requirements.txt" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install -r "${SERVICE_HOME}/requirements.txt"
  fi
  local req_file="${SERVICE_HOME}/app/requirements.txt"
  if [[ -f "$req_file" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install -r "$req_file" || true
  fi
  if [[ -n "${LIGHTON_OCR_PIP_EXTRA:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install ${LIGHTON_OCR_PIP_EXTRA}
  fi
}

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil
  require_cmd python3

  LABEL="com.lighton-ocr.server"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"

  sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/lighton-ocr

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    note "Creating system user '${SERVICE_USER}'..."
    next_uid=501
    while id -u "$next_uid" >/dev/null 2>&1; do
      ((next_uid++))
    done
    sudo dscl . -create /Users/"${SERVICE_USER}"
    sudo dscl . -create /Users/"${SERVICE_USER}" UserShell /bin/bash
    sudo dscl . -create /Users/"${SERVICE_USER}" RealName "LightOnOCR Service User"
    sudo dscl . -create /Users/"${SERVICE_USER}" UniqueID "$next_uid"
    sudo dscl . -create /Users/"${SERVICE_USER}" PrimaryGroupID 20
    sudo dscl . -create /Users/"${SERVICE_USER}" NFSHomeDirectory "${SERVICE_HOME}"
    sudo createhomedir -u "${SERVICE_USER}" -c 2>/dev/null || true
  fi

  sudo chown -R "${SERVICE_USER}":staff "${SERVICE_HOME}" /var/log/lighton-ocr
  sudo chmod 750 "${SERVICE_HOME}" /var/log/lighton-ocr

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${SERVICE_USER}" -H python3 -m venv "$VENV_PATH"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" httpx

  ensure_git_lfs
  clone_repo
  install_runner
  install_requirements_file
  install_requirements
  install_env_file
  install_shim

  sudo sed "s/<string>lightonocr<\/string>/<string>${SERVICE_USER}<\/string>/" "$SRC" | sudo tee "$DST" >/dev/null
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

    sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/lighton-ocr
    sudo chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}" /var/log/lighton-ocr
    sudo chmod 750 "${SERVICE_HOME}" /var/log/lighton-ocr

    PYTHON_BIN="${LIGHTON_OCR_PYTHON_BIN:-}"
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

    ensure_git_lfs
    clone_repo
    install_runner
    install_requirements_file
    install_requirements
    install_env_file
    install_shim

    SERVICE_UNIT_SRC="${HERE}/../systemd/lighton-ocr.service"
    SERVICE_UNIT_DST="/etc/systemd/system/lighton-ocr.service"
    sudo cp "$SERVICE_UNIT_SRC" "$SERVICE_UNIT_DST"
    sudo chmod 644 "$SERVICE_UNIT_DST"

    sudo systemctl daemon-reload
    sudo systemctl enable --now lighton-ocr.service
    exit 0
  fi
fi

note "ERROR: unsupported OS or missing systemctl/launchctl."
exit 1
