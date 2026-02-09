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
SERVICE_USER="${SKYREELS_USER:-skyreels}"
SERVICE_HOME="${SKYREELS_HOME:-/var/lib/skyreels-v2}"
VENV_PATH="${SERVICE_HOME}/venv"
ENV_FILE="/etc/skyreels-v2/skyreels-v2.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../shim/skyreels_shim_server.py"
TOOLS_SRC="${HERE}/../tools/run_skyreels_cli.py"
TOOLS_COMPAT_SRC="${HERE}/../tools/run_skyreels.py"
ENV_TEMPLATE="${HERE}/../env/skyreels-v2.env.example"
REPO_URL_DEFAULT="https://github.com/SkyworkAI/SkyReels-V2"

venv_python() {
  if [[ -x "${VENV_PATH}/bin/python3" ]]; then
    echo "${VENV_PATH}/bin/python3"
  else
    echo "${VENV_PATH}/bin/python"
  fi
}

maybe_patch_env_run_command() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 0
  fi
  local vpy
  vpy="$(venv_python)"
  # If subprocess mode is configured, force venv python so deps (e.g. imageio) are found.
  if grep -qE '^SKYREELS_RUN_COMMAND=.*run_skyreels(_cli)?\.py' "$ENV_FILE"; then
    if ! grep -q "${VENV_PATH}/bin/python" "$ENV_FILE"; then
      note "Patching SKYREELS_RUN_COMMAND in ${ENV_FILE} to use venv python (${vpy})"
      local runner_path="${SERVICE_HOME}/tools/run_skyreels_cli.py"
      if command -v perl >/dev/null 2>&1; then
        sudo perl -pi -e 's|^SKYREELS_RUN_COMMAND=.*run_skyreels(_cli)?\.py.*$|SKYREELS_RUN_COMMAND='"${vpy//\//\/}"' '"${runner_path//\//\/}"'|g' "$ENV_FILE"
      else
        sudo sed -i.bak "s|^SKYREELS_RUN_COMMAND=.*run_skyreels\(_cli\)\?\.py.*$|SKYREELS_RUN_COMMAND=${vpy} ${runner_path}|" "$ENV_FILE" || true
      fi
    fi
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

install_shim() {
  if [[ ! -f "$SHIM_SRC" ]]; then
    echo "ERROR: skyreels_shim_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${SERVICE_HOME}/skyreels_shim_server.py"
  sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/skyreels_shim_server.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/skyreels_shim_server.py"
  sudo chmod 644 "${SERVICE_HOME}/skyreels_shim_server.py"

  if [[ -f "$TOOLS_SRC" ]]; then
    sudo mkdir -p "${SERVICE_HOME}/tools"
    sudo cp -f "$TOOLS_SRC" "${SERVICE_HOME}/tools/run_skyreels_cli.py"
    sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/tools/run_skyreels_cli.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/tools/run_skyreels_cli.py"
    sudo chmod 755 "${SERVICE_HOME}/tools/run_skyreels_cli.py"
  fi
  if [[ -f "$TOOLS_COMPAT_SRC" ]]; then
    sudo mkdir -p "${SERVICE_HOME}/tools"
    sudo cp -f "$TOOLS_COMPAT_SRC" "${SERVICE_HOME}/tools/run_skyreels.py"
    sudo chown "${SERVICE_USER}":staff "${SERVICE_HOME}/tools/run_skyreels.py" 2>/dev/null || sudo chown "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}/tools/run_skyreels.py"
    sudo chmod 755 "${SERVICE_HOME}/tools/run_skyreels.py"
  fi
}

clone_repo() {
  local repo_url
  repo_url="${SKYREELS_REPO_URL:-$REPO_URL_DEFAULT}"
  if [[ -z "$repo_url" ]]; then
    return 0
  fi
  if [[ ! -d "${SERVICE_HOME}/app/.git" ]]; then
    sudo -u "${SERVICE_USER}" -H git clone "$repo_url" "${SERVICE_HOME}/app"
  else
    sudo -u "${SERVICE_USER}" -H git -C "${SERVICE_HOME}/app" pull --ff-only || true
  fi
}

install_requirements() {
  local req_file="${SERVICE_HOME}/app/requirements.txt"
  if [[ -f "$req_file" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install -r "$req_file"
  fi
  if [[ -n "${SKYREELS_PIP_EXTRA:-}" ]]; then
    sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install ${SKYREELS_PIP_EXTRA}
  fi
}

install_runtime_deps() {
  # Upstream requirements files are not always complete, and failures should not be silent.
  # Explicitly install the core runtime deps used by the shim + runner + upstream scripts.
  local pip_bin="$VENV_PATH/bin/pip"

  local -a torch_pip_args
  torch_pip_args=()
  if [[ -n "${SKYREELS_TORCH_INDEX_URL:-}" ]]; then
    # If index-url is overridden, keep PyPI available as an extra index.
    torch_pip_args+=(--index-url "$SKYREELS_TORCH_INDEX_URL" --extra-index-url https://pypi.org/simple)
  elif [[ -n "${SKYREELS_TORCH_EXTRA_INDEX_URL:-}" ]]; then
    torch_pip_args+=(--extra-index-url "$SKYREELS_TORCH_EXTRA_INDEX_URL")
  elif [[ -n "${AI_TORCH_INDEX_URL:-}" ]]; then
    torch_pip_args+=(--index-url "$AI_TORCH_INDEX_URL" --extra-index-url https://pypi.org/simple)
  elif [[ -n "${AI_TORCH_EXTRA_INDEX_URL:-}" ]]; then
    torch_pip_args+=(--extra-index-url "$AI_TORCH_EXTRA_INDEX_URL")
  fi

  # torch/torchvision are required at runtime (generate_video.py imports torch).
  sudo -u "${SERVICE_USER}" -H "$pip_bin" install "${torch_pip_args[@]}" torch torchvision

  # Core runtime deps observed in the upstream SkyReels-V2 scripts.
  sudo -u "${SERVICE_USER}" -H "$pip_bin" install \
    diffusers \
    transformers \
    huggingface_hub \
    safetensors \
    numpy \
    tqdm \
    pillow \
    imageio \
    einops \
    decord \
    ftfy \
    regex \
    moviepy
}

validate_runtime_imports() {
  local vpy
  vpy="$(venv_python)"
  sudo -u "${SERVICE_USER}" -H "$vpy" - <<'PY'
import importlib

required = [
    "fastapi",
    "uvicorn",
    "httpx",
    "imageio",
    "torch",
    "torchvision",
    "diffusers",
    "transformers",
    "huggingface_hub",
    "safetensors",
    "numpy",
    "tqdm",
    "PIL",
    "einops",
    "decord",
    "ftfy",
    "regex",
    "moviepy",
]

missing = []
for name in required:
    try:
        importlib.import_module(name)
    except Exception as e:
        missing.append((name, repr(e)))

if missing:
    lines = ["Missing required Python modules:"]
    lines += [f"- {name}: {err}" for name, err in missing]
    raise SystemExit("\n".join(lines))

print("SkyReels venv import check OK")
PY
}

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil
  require_cmd python3

  LABEL="com.skyreels-v2.server"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"

  sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/skyreels-v2 "${SERVICE_HOME}/out"

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    note "Creating system user '${SERVICE_USER}'..."
    next_uid=501
    while id -u "$next_uid" >/dev/null 2>&1; do
      ((next_uid++))
    done
    sudo dscl . -create /Users/"${SERVICE_USER}"
    sudo dscl . -create /Users/"${SERVICE_USER}" UserShell /bin/bash
    sudo dscl . -create /Users/"${SERVICE_USER}" RealName "SkyReels Service User"
    sudo dscl . -create /Users/"${SERVICE_USER}" UniqueID "$next_uid"
    sudo dscl . -create /Users/"${SERVICE_USER}" PrimaryGroupID 20
    sudo dscl . -create /Users/"${SERVICE_USER}" NFSHomeDirectory "${SERVICE_HOME}"
    sudo createhomedir -u "${SERVICE_USER}" -c 2>/dev/null || true
  fi

  sudo chown -R "${SERVICE_USER}":staff "${SERVICE_HOME}" /var/log/skyreels-v2
  sudo chmod 750 "${SERVICE_HOME}" /var/log/skyreels-v2

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${SERVICE_USER}" -H python3 -m venv "$VENV_PATH"
  fi

  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${SERVICE_USER}" -H "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" httpx

  clone_repo
  install_runtime_deps
  install_requirements
  validate_runtime_imports
  install_env_file
  maybe_patch_env_run_command
  install_shim

  sudo sed "s/<string>skyreels<\/string>/<string>${SERVICE_USER}<\/string>/" "$SRC" | sudo tee "$DST" >/dev/null
  sudo chown root:wheel "$DST" 2>/dev/null || sudo chown root:root "$DST"
  sudo chmod 644 "$DST"
  sudo plutil -lint "$DST" >/dev/null

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

    sudo mkdir -p "${SERVICE_HOME}" "${SERVICE_HOME}/cache" "${SERVICE_HOME}/tmp" /var/log/skyreels-v2 "${SERVICE_HOME}/out"
    sudo chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${SERVICE_HOME}" /var/log/skyreels-v2
    sudo chmod 750 "${SERVICE_HOME}" /var/log/skyreels-v2

    PYTHON_BIN="${SKYREELS_PYTHON_BIN:-}"
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
    install_runtime_deps
    install_requirements
    validate_runtime_imports
    install_env_file
    maybe_patch_env_run_command
    install_shim

    SERVICE_UNIT_SRC="${HERE}/../systemd/skyreels-v2.service"
    SERVICE_UNIT_DST="/etc/systemd/system/skyreels-v2.service"
    sudo cp "$SERVICE_UNIT_SRC" "$SERVICE_UNIT_DST"
    sudo chmod 644 "$SERVICE_UNIT_DST"

    sudo systemctl daemon-reload
    sudo systemctl enable --now skyreels-v2.service
    exit 0
  fi
fi

note "ERROR: unsupported OS or missing systemctl/launchctl."
exit 1
