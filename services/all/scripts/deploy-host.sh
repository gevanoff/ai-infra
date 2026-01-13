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
  
  if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo "Warning: Deploy script not found: $DEPLOY_SCRIPT"
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

    # Remote repo layout assumptions mirror local:
    #   <remote_base>/ai-infra
    #   <remote_base>/gateway
    # Override with AI_INFRA_REMOTE_BASE, defaults to ~/ai
    REMOTE_BASE="${AI_INFRA_REMOTE_BASE:-~/ai}"
    REMOTE_AI_INFRA_ROOT="${REMOTE_BASE%/}/ai-infra"
    REMOTE_GATEWAY_ROOT="${REMOTE_BASE%/}/gateway"

    # If deploying gateway, ensure we have a sibling gateway checkout locally so it can be synced.
    if [ "$role" == "gateway" ] && [ ! -f "$GATEWAY_ROOT/app/main.py" ]; then
      echo "Error: gateway repo not found next to ai-infra at: $GATEWAY_ROOT" >&2
      echo "Hint: clone gateway as a sibling of ai-infra, or set GATEWAY_SRC_DIR when running the gateway deploy script locally." >&2
      exit 1
    fi

    # Ensure remote base exists
    ssh "$HOSTNAME" "mkdir -p ${REMOTE_BASE}" || true

    # Sync ai-infra
    rsync -az --delete \
      --exclude='.git' \
      --exclude='*.pyc' \
      --exclude='__pycache__' \
      "$AI_INFRA_ROOT/" "$HOSTNAME:${REMOTE_AI_INFRA_ROOT}/"

    # Sync gateway if present (needed for remote gateway deployments; harmless otherwise)
    if [ -d "$GATEWAY_ROOT" ]; then
      rsync -az --delete \
        --exclude='.git' \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        "$GATEWAY_ROOT/" "$HOSTNAME:${REMOTE_GATEWAY_ROOT}/"
    fi

    # Then run the deploy script on the remote host
    ssh "$HOSTNAME" "cd ${REMOTE_AI_INFRA_ROOT}/services/$role && ./scripts/deploy.sh"
  fi
  
  echo "✓ $role deployed"
  echo ""
done

echo "=== Deployment to $HOST complete ==="
