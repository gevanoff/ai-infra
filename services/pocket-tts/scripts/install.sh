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

ensure_firewall_allow_tcp_port_from_cidr() {
  local cidr="$1"
  local port="$2"

  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status="$(sudo ufw status 2>/dev/null || true)"
    if echo "$ufw_status" | grep -qiE '^Status:\s+active'; then
      note "Configuring firewall via ufw: allow tcp/${port} from ${cidr}"
      if sudo ufw allow from "$cidr" to any port "$port" proto tcp comment "pocket-tts" >/dev/null 2>&1; then
        return 0
      fi
      sudo ufw allow from "$cidr" to any port "$port" proto tcp >/dev/null
      return 0
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
      local rule
      rule="rule family=ipv4 source address=${cidr} port protocol=tcp port=${port} accept"
      note "Configuring firewall via firewalld rich rule: allow tcp/${port} from ${cidr}"
      if sudo firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
        note "Firewall already allows tcp/${port} from ${cidr} (firewalld)"
      else
        sudo firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
        sudo firewall-cmd --reload >/dev/null
      fi
      return 0
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    note "Configuring firewall via iptables: allow tcp/${port} from ${cidr}"
    if sudo iptables -C INPUT -p tcp -s "$cidr" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      note "Firewall already allows tcp/${port} from ${cidr} (iptables)"
      return 0
    fi
    sudo iptables -I INPUT 1 -p tcp -s "$cidr" --dport "$port" -j ACCEPT

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1 && [ -f /etc/debian_version ]; then
        note "Installing netfilter-persistent/iptables-persistent for iptables rule persistence..."
        sudo -E env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
        sudo -E env DEBIAN_FRONTEND=noninteractive apt-get install -y netfilter-persistent iptables-persistent >/dev/null 2>&1 || true
      fi
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
      sudo netfilter-persistent save >/dev/null 2>&1 || true
      if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
      fi
      note "✓ persisted iptables rules via netfilter-persistent"
    else
      note "NOTE: iptables rule may not persist across reboot; install iptables-persistent or netfilter-persistent."
    fi
    return 0
  fi

  note "NOTE: No supported firewall manager found (ufw/firewalld/iptables). Ensure tcp/${port} is allowed from ${cidr}."
}

OS="$(uname -s 2>/dev/null || echo unknown)"
POCKET_TTS_USER="${POCKET_TTS_USER:-pockettts}"
POCKET_TTS_HOME="${POCKET_TTS_HOME:-/var/lib/pocket-tts}"
VENV_PATH="${POCKET_TTS_HOME}/env"
ENV_FILE="/etc/pocket-tts/pocket-tts.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${HERE}/../pocket_tts_server.py"
ENV_TEMPLATE="${HERE}/../env/pocket-tts.env.example"

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
    echo "ERROR: pocket_tts_server.py not found at ${SHIM_SRC}" >&2
    exit 1
  fi
  sudo cp -f "$SHIM_SRC" "${POCKET_TTS_HOME}/pocket_tts_server.py"
  sudo chown "${POCKET_TTS_USER}":"${POCKET_TTS_USER}" "${POCKET_TTS_HOME}/pocket_tts_server.py"
  sudo chmod 644 "${POCKET_TTS_HOME}/pocket_tts_server.py"
}

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil
  require_cmd python3

  LABEL="com.pocket-tts.server"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"

  sudo mkdir -p "${POCKET_TTS_HOME}" "${POCKET_TTS_HOME}/cache" "${POCKET_TTS_HOME}/tmp" /var/log/pocket-tts

  # Create the user if it doesn't exist
  if ! id -u "${POCKET_TTS_USER}" >/dev/null 2>&1; then
    note "Creating system user '${POCKET_TTS_USER}'..."
    # Find the next available UID (starting from 501 for system users)
    local next_uid=501
    while id -u "$next_uid" >/dev/null 2>&1; do
      ((next_uid++))
    done
    sudo dscl . -create /Users/"${POCKET_TTS_USER}"
    sudo dscl . -create /Users/"${POCKET_TTS_USER}" UserShell /bin/bash
    sudo dscl . -create /Users/"${POCKET_TTS_USER}" RealName "Pocket TTS Service User"
    sudo dscl . -create /Users/"${POCKET_TTS_USER}" UniqueID "$next_uid"
    sudo dscl . -create /Users/"${POCKET_TTS_USER}" PrimaryGroupID 20  # staff group
    sudo dscl . -create /Users/"${POCKET_TTS_USER}" NFSHomeDirectory "${POCKET_TTS_HOME}"
    sudo dscl . -passwd /Users/"${POCKET_TTS_USER}" "*"  # Set no password
    sudo createhomedir -u "${POCKET_TTS_USER}" -c 2>/dev/null || true
  fi

  sudo chown -R "${POCKET_TTS_USER}":staff "${POCKET_TTS_HOME}" /var/log/pocket-tts
  sudo chmod 750 "${POCKET_TTS_HOME}" /var/log/pocket-tts

  if [[ ! -d "$VENV_PATH" ]]; then
    sudo -u "${POCKET_TTS_USER}" -H python3 -m venv "$VENV_PATH"
  fi

  sudo -u "${POCKET_TTS_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${POCKET_TTS_USER}" -H "$VENV_PATH/bin/pip" install pocket-tts fastapi "uvicorn[standard]" pydantic

  install_env_file
  install_shim

  sudo sed "s/<string>pockettts<\/string>/<string>${POCKET_TTS_USER}<\/string>/" "$SRC" | sudo tee "$DST" >/dev/null
  sudo chown root:wheel "$DST"
  sudo chmod 644 "$DST"
  sudo plutil -lint "$DST" >/dev/null

  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$DST"
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
        note "NOTE: this installer targets Ubuntu 22.04; detected ${ID:-unknown} ${VERSION_ID:-unknown}."
      fi
    fi

    if ! id -u "${POCKET_TTS_USER}" >/dev/null 2>&1; then
      sudo useradd --system --create-home --home-dir "${POCKET_TTS_HOME}" --shell /bin/bash "${POCKET_TTS_USER}"
    fi

    sudo mkdir -p "${POCKET_TTS_HOME}" "${POCKET_TTS_HOME}/cache" "${POCKET_TTS_HOME}/tmp" /var/log/pocket-tts
    sudo chown -R "${POCKET_TTS_USER}":"${POCKET_TTS_USER}" "${POCKET_TTS_HOME}" /var/log/pocket-tts
    sudo chmod 750 "${POCKET_TTS_HOME}" /var/log/pocket-tts

    PYTHON_BIN="${POCKET_TTS_PYTHON_BIN:-}"
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
      sudo -u "${POCKET_TTS_USER}" -H "$PYTHON_BIN" -m venv "$VENV_PATH"
    fi

    sudo -u "${POCKET_TTS_USER}" -H "$VENV_PATH/bin/pip" install --upgrade pip setuptools wheel
    sudo -u "${POCKET_TTS_USER}" -H "$VENV_PATH/bin/pip" install pocket-tts fastapi "uvicorn[standard]" pydantic

    install_env_file
    install_shim

    SERVICE_FILE="/etc/systemd/system/pocket-tts.service"
    sudo tee "$SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=Pocket TTS FastAPI Shim
After=network.target

[Service]
Type=simple
User=${POCKET_TTS_USER}
Group=${POCKET_TTS_USER}
WorkingDirectory=${POCKET_TTS_HOME}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_PATH}/bin/uvicorn pocket_tts_server:app --host \${POCKET_TTS_HOST} --port \${POCKET_TTS_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable --now pocket-tts >/dev/null 2>&1 || sudo systemctl restart pocket-tts

    if [[ -f "$ENV_FILE" ]]; then
      local_port=$(awk -F= '/POCKET_TTS_PORT/{print $2}' "$ENV_FILE" | tr -d ' ')
      local_port=${local_port:-9940}
      local_cidrs=$(awk -F= '/POCKET_TTS_ALLOWED_CIDRS/{print $2}' "$ENV_FILE" | tr -d '"')
      local_cidrs=${local_cidrs:-10.10.22.0/24}
      for cidr in $local_cidrs; do
        ensure_firewall_allow_tcp_port_from_cidr "$cidr" "$local_port"
      done
    fi

    echo "✓ pocket-tts service enabled/started (systemd)" >&2
    exit 0
  fi

  echo "ERROR: systemctl not found; cannot manage pocket-tts as a service on Linux." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
