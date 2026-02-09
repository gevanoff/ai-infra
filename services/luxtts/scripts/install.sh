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

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    note "ERROR: this installer must run as root (sudo not found)."
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

OS="$(uname -s 2>/dev/null || echo unknown)"
SERVICE_USER="${LUXTTS_USER:-luxtts}"
SERVICE_HOME="${LUXTTS_HOME:-/var/lib/luxtts}"
VENV_PATH="${SERVICE_HOME}/venv"
ENV_FILE="/etc/luxtts/luxtts.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../lux_tts_server.py"
ENV_TEMPLATE="${HERE}/../env/luxtts.env.example"
REPO_URL_DEFAULT="https://github.com/ysharma3501/LuxTTS"
VENV_PY=""

venv_python() {
  if [[ -n "$VENV_PY" ]]; then
    echo "$VENV_PY"
    return 0
  fi
  if [[ -x "${VENV_PATH}/bin/python3" ]]; then
    VENV_PY="${VENV_PATH}/bin/python3"
  else
    VENV_PY="${VENV_PATH}/bin/python"
  fi
  echo "$VENV_PY"
}

ensure_venv_package() {
  local pkg="$1"
  local venv_py
  venv_py="$(venv_python)"
  if ! sudo -u "${SERVICE_USER}" -H "$venv_py" - <<PY >/dev/null 2>&1
import importlib
import sys
sys.exit(0 if importlib.util.find_spec("${pkg}") else 1)
PY
  then
    sudo -u "${SERVICE_USER}" -H "$venv_py" -m pip install "${pkg}"
  fi
}

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

ensure_libsndfile() {
  if [[ "$OS" == "Darwin" ]]; then
    local brew_bin=""
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      brew_bin="/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_bin="/usr/local/bin/brew"
    fi

    if [[ -n "$brew_bin" ]]; then
      # Homebrew refuses to run as root; use the invoking user when available.
      if [[ "${EUID:-0}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "${SUDO_USER}" -H "$brew_bin" list libsndfile >/dev/null 2>&1 || sudo -u "${SUDO_USER}" -H "$brew_bin" install libsndfile
      else
        "$brew_bin" list libsndfile >/dev/null 2>&1 || "$brew_bin" install libsndfile
      fi
    fi
    return 0
  fi
  if [[ "$OS" == "Linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo -E env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      sudo -E env DEBIAN_FRONTEND=noninteractive apt-get install -y libsndfile1 >/dev/null 2>&1 || true
    fi
    return 0
  fi
}

maybe_patch_env_run_command() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 0
  fi
  local vpy
  vpy="$(venv_python)"
  if grep -qE '^LUXTTS_RUN_COMMAND=python3\s+scripts/run_luxtts\.py\s*$' "$ENV_FILE"; then
    note "Patching LUXTTS_RUN_COMMAND in ${ENV_FILE} to use venv python (${vpy})"
    if command -v perl >/dev/null 2>&1; then
      sudo perl -pi -e 's/^LUXTTS_RUN_COMMAND=python3\s+scripts\/run_luxtts\.py\s*$/LUXTTS_RUN_COMMAND='"${vpy//\//\/}"' \/var\/lib\/luxtts\/app\/scripts\/run_luxtts.py/' "$ENV_FILE"
    else
      sudo sed -i.bak "s|^LUXTTS_RUN_COMMAND=python3 scripts/run_luxtts.py\s*$|LUXTTS_RUN_COMMAND=${vpy} /var/lib/luxtts/app/scripts/run_luxtts.py|" "$ENV_FILE" || true
    fi
  fi
}

install_shim() {
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: lux_tts_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/lux_tts_server.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/lux_tts_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/lux_tts_server.py"
  sudo chmod 644 "${SERVICE_HOME}/lux_tts_server.py"

  if [[ -f "${HERE}/run_luxtts.py" ]]; then
    sudo mkdir -p "${SERVICE_HOME}/app/scripts"
    sudo cp -f "${HERE}/run_luxtts.py" "${SERVICE_HOME}/app/scripts/run_luxtts.py"
    sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/app/scripts/run_luxtts.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/app/scripts/run_luxtts.py"
    sudo chmod 755 "${SERVICE_HOME}/app/scripts/run_luxtts.py"
  fi
}

clone_repo() {
  local repo_url
  repo_url="${LUXTTS_REPO_URL:-$REPO_URL_DEFAULT}"
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
  if [[ -n "${LUXTTS_PIP_EXTRA:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install ${LUXTTS_PIP_EXTRA}
  fi
}

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil
  require_cmd python3

  LABEL="com.luxtts.server"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"

  sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/luxtts

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    note "Creating system user '${SERVICE_USER}'..."
    next_uid=501
    while id -u "$next_uid" >/dev/null 2>&1; do
      ((next_uid++))
    done
    sudo dscl . -create /Users/"${SERVICE_USER}"
    sudo dscl . -create /Users/"${SERVICE_USER}" UserShell /bin/bash
    sudo dscl . -create /Users/"${SERVICE_USER}" RealName "LuxTTS Service User"
    sudo dscl . -create /Users/"${SERVICE_USER}" UniqueID "$next_uid"
    sudo dscl . -create /Users/"${SERVICE_USER}" PrimaryGroupID 20
    sudo dscl . -create /Users/"${SERVICE_USER}" NFSHomeDirectory "${SERVICE_HOME}"
    sudo createhomedir -u "${SERVICE_USER}" -c 2>/dev/null || true
  fi

  sudo chown -R "${SERVICE_USER}":staff "${SERVICE_HOME}" /var/log/luxtts
  sudo chmod 750 "${SERVICE_HOME}" /var/log/luxtts

  # Prefer Homebrew python3.11 on macOS (common on modern Macs with brew).
  MAC_PYTHON_BIN="${LUXTTS_MAC_PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
  if command -v "$MAC_PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN_FOR_VENV="$MAC_PYTHON_BIN"
  else
    PYTHON_BIN_FOR_VENV="python3"
  fi

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${SERVICE_USER}" -H "$PYTHON_BIN_FOR_VENV" -m venv "$VENV_PATH"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" httpx
  ensure_libsndfile
  ensure_venv_package "soundfile"

  clone_repo
  install_requirements
  install_env_file
  maybe_patch_env_run_command
  install_shim

  sudo sed "s/<string>luxtts<\/string>/<string>${SERVICE_USER}<\/string>/" "$SRC" | sudo tee "$DST" >/dev/null
  sudo chown root:wheel "$DST" 2>/dev/null || sudo chown root:root "$DST"
  sudo chmod 644 "$DST"
  plutil -lint "$DST" >/dev/null

  launchctl bootout system/"$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap system "$DST"; then
    if launchctl print system/"$LABEL" >/dev/null 2>&1; then
      note "WARN: launchctl bootstrap failed for ${LABEL}, but job is already loaded; continuing."
    else
      note "ERROR: launchctl bootstrap failed for ${LABEL}."
      exit 1
    fi
  fi
  launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
      sudo useradd --system --create-home --home-dir "${SERVICE_HOME}" --shell /bin/bash "${SERVICE_USER}"
    fi

    sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/luxtts
    sudo chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}" /var/log/luxtts
    sudo chmod 750 "${SERVICE_HOME}" /var/log/luxtts

    PYTHON_BIN="${LUXTTS_PYTHON_BIN:-}"
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
    ensure_libsndfile
    ensure_venv_package "soundfile"

    clone_repo
    install_requirements
    install_env_file
    maybe_patch_env_run_command
    install_shim

    SERVICE_UNIT_SRC="${HERE}/../systemd/luxtts.service"
    SERVICE_UNIT_DST="/etc/systemd/system/luxtts.service"
    sudo cp "$SERVICE_UNIT_SRC" "$SERVICE_UNIT_DST"
    sudo chmod 644 "$SERVICE_UNIT_DST"

    sudo systemctl daemon-reload
    sudo systemctl enable --now luxtts.service
    exit 0
  fi
fi

note "ERROR: unsupported OS or missing systemctl/launchctl."
exit 1
