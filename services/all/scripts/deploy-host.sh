#!/bin/bash
# Deploy all services for a specific host
#
# Usage:
#   ./deploy-host.sh ai2          # Deploy gateway + mlx to ai2
#   ./deploy-host.sh ada2         # Deploy invokeai to ada2
#   ./deploy-host.sh ai1          # Deploy ollama to ai1

set -e

HOST=$1

if [ -z "$HOST" ]; then
  echo "Usage: $0 <hostname>"
  echo "Available hosts: ai2, ai1, ada2"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local repo layout assumptions:
#   <workspace_root>/ai-infra
#   <workspace_root>/gateway
AI_INFRA_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "$AI_INFRA_ROOT/.." && pwd)"
GATEWAY_ROOT="${WORKSPACE_ROOT}/gateway"

HOSTS_FILE="$AI_INFRA_ROOT/hosts.yaml"

if [ ! -f "$HOSTS_FILE" ]; then
  echo "Error: hosts.yaml not found at $HOSTS_FILE"
  exit 1
fi

# Check if yq is available, install if missing on Linux
if ! command -v yq &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Installing yq..."
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
  else
    echo "Error: yq is required but not installed."
    echo "Install with: brew install yq (macOS)"
    exit 1
  fi
fi

# Get hostname for this host
HOSTNAME=$(yq ".hosts.$HOST.hostname" "$HOSTS_FILE")
if [ "$HOSTNAME" == "null" ]; then
  echo "Error: Host '$HOST' not found in hosts.yaml"
  exit 1
fi

# Get OS for this host (used for remote login shell selection)
REMOTE_OS=$(yq ".hosts.$HOST.os" "$HOSTS_FILE")
if [ "$REMOTE_OS" == "null" ] || [ -z "$REMOTE_OS" ]; then
  REMOTE_OS="linux"
fi

quote_sh() {
  # Single-quote a string for POSIX-ish shells.
  local s="$1"
  s=${s//\'/\'"\'"\'}
  printf "'%s'" "$s"
}

ssh_login_exec() {
  local hostname="$1"
  local remote_os="$2"
  local cmd="$3"

  # On Ubuntu/Linux, ensure ~/.profile is loaded.
  if [[ "$remote_os" == "ubuntu" || "$remote_os" == "linux" ]]; then
    cmd="if [ -f ~/.profile ]; then . ~/.profile; fi; ${cmd}"
  fi

  local q
  q="$(quote_sh "$cmd")"

  if [[ "$remote_os" == "ubuntu" || "$remote_os" == "linux" ]]; then
    ssh "$hostname" "bash -lc ${q}"
    return $?
  fi

  if [[ "$remote_os" == "macos" || "$remote_os" == "darwin" ]]; then
    ssh "$hostname" "zsh -lc ${q}"
    return $?
  fi

  ssh "$hostname" "bash -lc ${q}"
}

resolve_remote_base() {
  # Prefer a local override; otherwise ask the remote host (login shell) for AI_INFRA_BASE.
  if [ -n "${AI_INFRA_REMOTE_BASE:-}" ]; then
    echo "$AI_INFRA_REMOTE_BASE"
    return 0
  fi
  ssh_login_exec "$HOSTNAME" "$REMOTE_OS" 'echo "${AI_INFRA_BASE:-$HOME/ai}"'
}

# Get roles for this host
ROLES=$(yq ".hosts.$HOST.roles[]" "$HOSTS_FILE")
if [ -z "$ROLES" ]; then
  echo "Error: No roles defined for host '$HOST'"
  exit 1
fi

echo "=== Deploying to $HOST ($HOSTNAME) ==="
echo "Roles: $(echo $ROLES | tr '\n' ' ')"
echo ""

for role in $ROLES; do
  echo ">>> Deploying $role..."
  
  SERVICE_DIR="$AI_INFRA_ROOT/services/$role"
  DEPLOY_SCRIPT="$SERVICE_DIR/scripts/deploy.sh"
  RESTART_SCRIPT="$SERVICE_DIR/scripts/restart.sh"
  
  if [ ! -f "$DEPLOY_SCRIPT" ]; then
    # Many roles (ollama/mlx/nexa) are managed via install/restart scripts and do not need a deploy step.
    if [ -f "$RESTART_SCRIPT" ]; then
      echo "No deploy script for ${role}; running restart instead."
    else
      echo "No deploy script for ${role}; skipping."
    fi

    CURRENT_HOST=$(hostname)
    if [ "$CURRENT_HOST" == "$HOST" ] || [ "$CURRENT_HOST" == "$HOSTNAME" ]; then
      if [ -f "$RESTART_SCRIPT" ]; then
        cd "$SERVICE_DIR"
        ./scripts/restart.sh || true
      fi
    else
      if [ -f "$RESTART_SCRIPT" ]; then
        REMOTE_BASE="$(resolve_remote_base | tr -d '\r' | tail -n 1)"
        if [ -z "$REMOTE_BASE" ]; then
          echo "Error: could not resolve remote base directory on $HOSTNAME" >&2
          echo "Hint: set AI_INFRA_REMOTE_BASE locally or AI_INFRA_BASE in remote dotfiles." >&2
          exit 1
        fi
        REMOTE_AI_INFRA_ROOT="${REMOTE_BASE%/}/ai-infra"
        ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "cd \"${REMOTE_AI_INFRA_ROOT}/services/$role\" && ./scripts/restart.sh" || true
      fi
    fi
    echo "✓ $role processed"
    echo ""
    continue
  fi
  
  # Check if we're deploying to localhost or remote
  CURRENT_HOST=$(hostname)
  
  if [ "$CURRENT_HOST" == "$HOST" ] || [ "$CURRENT_HOST" == "$HOSTNAME" ]; then
    # Local deployment
    echo "Deploying locally..."
    cd "$SERVICE_DIR"
    ./scripts/deploy.sh
  else
    # Remote deployment via SSH
    echo "Deploying remotely to $HOSTNAME..."

    # Remote repo layout:
    #   <remote_base>/ai-infra
    #   <remote_base>/gateway
    # remote_base comes from local AI_INFRA_REMOTE_BASE override, else remote AI_INFRA_BASE (login shell), else $HOME/ai.
    REMOTE_BASE="$(resolve_remote_base | tr -d '\r' | tail -n 1)"
    if [ -z "$REMOTE_BASE" ]; then
      echo "Error: could not resolve remote base directory on $HOSTNAME" >&2
      echo "Hint: set AI_INFRA_REMOTE_BASE locally or AI_INFRA_BASE in remote dotfiles." >&2
      exit 1
    fi
    REMOTE_AI_INFRA_ROOT="${REMOTE_BASE%/}/ai-infra"
    REMOTE_GATEWAY_ROOT="${REMOTE_BASE%/}/gateway"

    # If deploying gateway, ensure we have a sibling gateway checkout locally so it can be synced.
    if [ "$role" == "gateway" ] && [ ! -f "$GATEWAY_ROOT/app/main.py" ]; then
      echo "Error: gateway repo not found next to ai-infra at: $GATEWAY_ROOT" >&2
      echo "Hint: clone gateway as a sibling of ai-infra, or set GATEWAY_SRC_DIR when running the gateway deploy script locally." >&2
      exit 1
    fi

    # Ensure remote base exists
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "mkdir -p \"${REMOTE_BASE}\"" || true

    # Sync ai-infra
    rsync -az --delete \
      --exclude='.git' \
      --exclude='*.pyc' \
      --exclude='__pycache__' \
      --exclude='env/' --exclude='.venv/' --exclude='venv/' \
      "$AI_INFRA_ROOT/" "$HOSTNAME:${REMOTE_AI_INFRA_ROOT}/"

    # Normalize line endings on the remote host (Windows -> macOS/Linux CRLF can break shebangs).
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "find \"${REMOTE_AI_INFRA_ROOT}/services\" -type f -name '*.sh' -exec perl -pi -e 's/\r$//' {} +" || true

    # Sync gateway if present (needed for remote gateway deployments; harmless otherwise)
    if [ -d "$GATEWAY_ROOT" ]; then
      rsync -az --delete \
        --exclude='.git' \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        --exclude='env/' --exclude='.venv/' --exclude='venv/' \
        --exclude='Library/' \
        "$GATEWAY_ROOT/" "$HOSTNAME:${REMOTE_GATEWAY_ROOT}/"

      ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "find \"${REMOTE_GATEWAY_ROOT}\" -type f -name '*.sh' -exec perl -pi -e 's/\r$//' {} +" || true
    fi

    # Then run the deploy script on the remote host
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "cd \"${REMOTE_AI_INFRA_ROOT}/services/$role\" && ./scripts/deploy.sh"
  fi
  
  echo "✓ $role deployed"
  echo ""
done

echo "=== Deployment to $HOST complete ==="
