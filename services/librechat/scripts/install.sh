#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat launchd scripts are macOS-only." >&2
  exit 1
fi

LABEL_APP="com.ai.librechat"
LABEL_MONGO="com.ai.librechat.mongodb"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="${HERE}/../launchd/${LABEL_APP}.plist.example"
SRC_MONGO="${HERE}/../launchd/${LABEL_MONGO}.plist.example"
DST_APP="/Library/LaunchDaemons/${LABEL_APP}.plist"
DST_MONGO="/Library/LaunchDaemons/${LABEL_MONGO}.plist"

PF_ANCHOR="/etc/pf.anchors/com.ai.librechat"
PF_CONF="/etc/pf.conf"
ALLOW_CIDR="${LIBRECHAT_ALLOW_CIDR:-10.10.22.0/24}"
LIBRECHAT_PORT="${LIBRECHAT_PORT:-3080}"

SKIP_PF=false
SKIP_BREW=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pf)
      SKIP_PF=true
      shift
      ;;
    --skip-brew)
      SKIP_BREW=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

require_cmd launchctl
require_cmd plutil
require_cmd openssl

find_first_existing() {
  for p in "$@"; do
    if [[ -z "$p" ]]; then
      continue
    fi

    # Never select our own wrapper scripts as the source binary.
    # If we do, we can end up with self-referential wrappers or malformed exec lines.
    if [[ "$p" == "/var/lib/librechat/bin/node" || "$p" == "/var/lib/librechat/bin/mongod" ]]; then
      continue
    fi

    if [[ -x "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

write_exec_wrapper() {
  local dst="$1"
  local target="$2"

  sudo tee "$dst" >/dev/null <<EOF
#!/bin/sh
exec "${target}" "\$@"
EOF
  sudo chown root:wheel "$dst"
  sudo chmod 755 "$dst"
}

ensure_secure_binaries() {
  # macOS LaunchDaemons are picky about executing binaries in user-writable trees.
  # Homebrew typically lives under /opt/homebrew which is writable by a user/admin group.
  # Workaround: use root-owned wrapper scripts in a root-owned, non-writable directory.
  # IMPORTANT: do NOT copy the Homebrew node binary directly, as it depends on adjacent
  # libnode.*.dylib via @rpath and will crash with OS_REASON_DYLD if moved.

  local bin_dir="/var/lib/librechat/bin"
  sudo mkdir -p "$bin_dir"
  sudo chown root:wheel "$bin_dir"
  sudo chmod 755 "$bin_dir"

  local node_src
  node_src="$(find_first_existing \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    "$(command -v node 2>/dev/null || true)" \
  )" || {
    echo "ERROR: node not found; install Node (brew install node)" >&2
    exit 2
  }

  local mongod_src
  mongod_src="$(find_first_existing \
    /opt/homebrew/bin/mongod \
    /opt/homebrew/opt/mongodb-community@8.0/bin/mongod \
    /opt/homebrew/opt/mongodb-community/bin/mongod \
    /usr/local/bin/mongod \
    "$(command -v mongod 2>/dev/null || true)" \
  )" || {
    echo "ERROR: mongod not found; install MongoDB (brew install mongodb-community@8.0)" >&2
    exit 2
  }

  write_exec_wrapper "$bin_dir/node" "$node_src"
  write_exec_wrapper "$bin_dir/mongod" "$mongod_src"
}

set_env_var_if_missing_or_empty() {
  local env_file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  if ! sudo grep -q "^${key}=" "$env_file"; then
    echo "${key}=${value}" | sudo tee -a "$env_file" >/dev/null
    return 0
  fi

  local current
  current=$(sudo awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "$env_file" 2>/dev/null || true)
  if [[ -z "${current}" ]]; then
    sudo sed -i '' "s|^${key}=.*$|${key}=${value}|" "$env_file"
  fi
}

ensure_env_secrets() {
  local env_file="$1"

  # Force gateway-only by default unless explicitly overridden.
  set_env_var_if_missing_or_empty "$env_file" "ENDPOINTS" "custom"

  # Secrets used for auth/session/encryption.
  set_env_var_if_missing_or_empty "$env_file" "JWT_SECRET" "$(openssl rand -hex 32)"
  set_env_var_if_missing_or_empty "$env_file" "JWT_REFRESH_SECRET" "$(openssl rand -hex 32)"
  set_env_var_if_missing_or_empty "$env_file" "CREDS_KEY" "$(openssl rand -hex 32)"
  set_env_var_if_missing_or_empty "$env_file" "CREDS_IV" "$(openssl rand -hex 16)"
}

ensure_service_user() {
  if id -u librechat >/dev/null 2>&1; then
    return 0
  fi

  echo "Creating service user 'librechat'..." >&2
  require_cmd dscl

  # Pick the next available UniqueID >= 501
  local next_uid
  next_uid=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -n 1)
  if [[ -z "${next_uid}" ]]; then
    next_uid=501
  else
    next_uid=$((next_uid + 1))
    if [[ "$next_uid" -lt 501 ]]; then
      next_uid=501
    fi
  fi

  sudo dscl . -create /Users/librechat
  sudo dscl . -create /Users/librechat RealName "LibreChat Service"
  sudo dscl . -create /Users/librechat UniqueID "$next_uid"
  sudo dscl . -create /Users/librechat PrimaryGroupID 20
  sudo dscl . -create /Users/librechat UserShell /usr/bin/false
  sudo dscl . -create /Users/librechat NFSHomeDirectory /var/lib/librechat
  sudo dscl . -create /Users/librechat IsHidden 1
  sudo dscl . -create /Users/librechat Password "*"
}

ensure_brew_packages() {
  if [[ "$SKIP_BREW" == "true" ]]; then
    echo "NOTE: --skip-brew set; not installing Node/Mongo via Homebrew." >&2
    return 0
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew not found (brew). Install it on ai2 first." >&2
    echo "Hint: https://brew.sh" >&2
    exit 2
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node via Homebrew..." >&2
    brew install node
  fi

  if ! command -v mongod >/dev/null 2>&1; then
    echo "Installing MongoDB Community via Homebrew..." >&2
    brew tap mongodb/brew
    brew install mongodb-community@8.0
  fi
}

install_pf_anchor() {
  if [[ "$SKIP_PF" == "true" ]]; then
    echo "NOTE: --no-pf set; skipping pf configuration." >&2
    return 0
  fi

  echo "Configuring pf allowlist for LibreChat TCP/${LIBRECHAT_PORT} from ${ALLOW_CIDR}..." >&2

  sudo mkdir -p "$(dirname "$PF_ANCHOR")"
  sudo tee "$PF_ANCHOR" >/dev/null <<EOF
# Managed by ai-infra (services/librechat)
# Allow LAN-only access to LibreChat.

# NOTE: pf is last-match-wins unless a rule is marked 'quick'.
# These rules must be 'quick' or a trailing block rule will override them.

# localhost
pass in quick on lo0 proto tcp from 127.0.0.1 to 127.0.0.1 port ${LIBRECHAT_PORT}
pass in quick on lo0 inet6 proto tcp from ::1 to ::1 port ${LIBRECHAT_PORT}

# LAN allowlist
pass in quick proto tcp from ${ALLOW_CIDR} to any port ${LIBRECHAT_PORT}

# default deny
block in proto tcp to any port ${LIBRECHAT_PORT}
EOF
  sudo chmod 644 "$PF_ANCHOR"

  if ! sudo grep -q 'anchor "com.ai.librechat"' "$PF_CONF"; then
    echo "Adding pf anchor to ${PF_CONF}..." >&2
    sudo tee -a "$PF_CONF" >/dev/null <<'EOF'

# ai-infra: LibreChat LAN allowlist
anchor "com.ai.librechat"
load anchor "com.ai.librechat" from "/etc/pf.anchors/com.ai.librechat"
EOF
  fi

  # Reload and enable pf (idempotent)
  sudo pfctl -f "$PF_CONF" >/dev/null
  sudo pfctl -E >/dev/null 2>&1 || true
}

seed_configs() {
  local env_example="${HERE}/../env/librechat.env.example"
  local yaml_example="${HERE}/../env/librechat.yaml.example"
  local env_dst="/var/lib/librechat/app/.env"
  local yaml_dst="/var/lib/librechat/app/librechat.yaml"

  if [[ ! -f "$env_dst" && -f "$env_example" ]]; then
    sudo cp "$env_example" "$env_dst"
    sudo chown librechat:staff "$env_dst"
    sudo chmod 640 "$env_dst"
    echo "NOTE: seeded ${env_dst}; set IMAGE_GEN_OAI_API_KEY and any other secrets." >&2
  fi

  # If the env exists (seeded previously or hand-created), ensure required secrets exist.
  ensure_env_secrets "$env_dst"

  if [[ ! -f "$yaml_dst" && -f "$yaml_example" ]]; then
    sudo cp "$yaml_example" "$yaml_dst"
    sudo chown librechat:staff "$yaml_dst"
    sudo chmod 640 "$yaml_dst"
    echo "NOTE: seeded ${yaml_dst}; customize endpoints as needed." >&2
  fi

  # Mongo config
  local mongo_cfg_example="${HERE}/../mongo/mongod.conf.example"
  local mongo_cfg_dst="/var/lib/librechat/mongo/mongod.conf"
  if [[ ! -f "$mongo_cfg_dst" && -f "$mongo_cfg_example" ]]; then
    sudo cp "$mongo_cfg_example" "$mongo_cfg_dst"
    sudo chown librechat:staff "$mongo_cfg_dst"
    sudo chmod 640 "$mongo_cfg_dst"
  fi
}

install_plists() {
  sudo cp "$SRC_MONGO" "$DST_MONGO"
  sudo cp "$SRC_APP" "$DST_APP"
  sudo chown root:wheel "$DST_MONGO" "$DST_APP"
  sudo chmod 644 "$DST_MONGO" "$DST_APP"

  sudo plutil -lint "$DST_MONGO" >/dev/null
  sudo plutil -lint "$DST_APP" >/dev/null

  # Start Mongo immediately.
  sudo launchctl bootout system/"$LABEL_MONGO" 2>/dev/null || true
  if ! sudo launchctl bootstrap system "$DST_MONGO"; then
    # Idempotence: if it is already loaded, continue.
    if sudo launchctl print system/"$LABEL_MONGO" >/dev/null 2>&1; then
      echo "NOTE: MongoDB job already loaded; continuing." >&2
    else
      echo "ERROR: launchctl bootstrap failed for MongoDB." >&2
      echo "Hint: this is often caused by launchd rejecting user-writable executables." >&2
      echo "Diag: ls -ld /var/lib/librechat/bin /var/lib/librechat/bin/mongod" >&2
      ls -ld /var/lib/librechat/bin /var/lib/librechat/bin/mongod 2>/dev/null || true
      exit 1
    fi
  fi
  sudo launchctl kickstart -k system/"$LABEL_MONGO"

  # Start LibreChat only if a deploy has populated the app entrypoint.
  if [[ -f "/var/lib/librechat/app/api/server/index.js" ]]; then
    sudo launchctl bootout system/"$LABEL_APP" 2>/dev/null || true
    if ! sudo launchctl bootstrap system "$DST_APP"; then
      if sudo launchctl print system/"$LABEL_APP" >/dev/null 2>&1; then
        echo "NOTE: LibreChat job already loaded; continuing." >&2
      else
        echo "ERROR: launchctl bootstrap failed for LibreChat." >&2
        echo "Diag: ls -ld /var/lib/librechat/bin /var/lib/librechat/bin/node" >&2
        ls -ld /var/lib/librechat/bin /var/lib/librechat/bin/node 2>/dev/null || true
        exit 1
      fi
    fi
    sudo launchctl kickstart -k system/"$LABEL_APP"
  else
    echo "NOTE: LibreChat app not deployed yet; plist installed but not started." >&2
    echo "Hint: run services/librechat/scripts/deploy.sh" >&2
  fi
}

echo "Installing LibreChat (macOS)" >&2

ensure_brew_packages
ensure_service_user

sudo mkdir -p /var/lib/librechat/{app,data,mongo} /var/lib/librechat/mongo/data /var/log/librechat
sudo chown -R librechat:staff /var/lib/librechat /var/log/librechat
sudo chmod -R u+rwX,g+rX,o-rwx /var/lib/librechat /var/log/librechat

ensure_secure_binaries

seed_configs
install_pf_anchor
install_plists

echo "Done. Next: run scripts/deploy.sh and then scripts/verify.sh" >&2
