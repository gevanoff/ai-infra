#!/bin/bash
# Deploy to all hosts defined in hosts.yaml
#
# Usage:
#   ./deploy-all.sh               # Deploy to all hosts
#   ./deploy-all.sh --dry-run     # Show what would be deployed

set -e

DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
  DRY_RUN=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOSTS_FILE="$REPO_ROOT/hosts.yaml"

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

# Get all host names from hosts.yaml
HOSTS=$(yq '.hosts | keys | .[]' "$HOSTS_FILE")

if [ -z "$HOSTS" ]; then
  echo "Error: No hosts defined in hosts.yaml"
  exit 1
fi

echo "=== AI Infrastructure Deployment ==="
echo "Deploying to: $(echo $HOSTS | tr '\n' ' ')"
echo ""

if [ "$DRY_RUN" == "true" ]; then
  echo "(Dry run - no changes will be made)"
  echo ""
  
  for host in $HOSTS; do
    hostname=$(yq ".hosts.$host.hostname" "$HOSTS_FILE")
    roles=$(yq ".hosts.$host.roles[]" "$HOSTS_FILE" | tr '\n' ' ')
    echo "$host ($hostname): $roles"
  done
  
  exit 0
fi

# Deploy to each host
FAILED_HOSTS=()

for host in $HOSTS; do
  echo "========================================"
  
  if "$SCRIPT_DIR/deploy-host.sh" "$host"; then
    echo "✓ $host deployment successful"
  else
    echo "✗ $host deployment failed"
    FAILED_HOSTS+=("$host")
  fi
  
  echo ""
done

echo "========================================"
echo "=== Deployment Summary ==="

if [ ${#FAILED_HOSTS[@]} -eq 0 ]; then
  echo "✓ All hosts deployed successfully"
  exit 0
else
  echo "✗ Failed hosts: ${FAILED_HOSTS[@]}"
  exit 1
fi
