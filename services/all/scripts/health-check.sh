#!/bin/bash
# Check health of all services across all hosts
#
# Usage:
#   ./health-check.sh                    # Check all services
#   ./health-check.sh --verbose          # Show detailed output
#   ./health-check.sh --host ai2         # Check only ai2

set -e

VERBOSE=false
FILTER_HOST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --host)
      FILTER_HOST="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOSTS_FILE="$REPO_ROOT/hosts.yaml"

if [ ! -f "$HOSTS_FILE" ]; then
  echo "Error: hosts.yaml not found at $HOSTS_FILE"
  exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
  echo "Error: yq is required but not installed."
  exit 1
fi

check_service() {
  local host=$1
  local hostname=$2
  local service=$3
  local port=$4
  local healthz=$5
  local requires_auth=$6
  
  local url="http://${hostname}:${port}${healthz}"
  
  # Build curl command
  local curl_cmd="curl -sf --max-time 5"
  
  # Add auth if required (read from env)
  if [ "$requires_auth" == "true" ] && [ -n "$GATEWAY_BEARER_TOKEN" ]; then
    curl_cmd="$curl_cmd -H 'Authorization: Bearer $GATEWAY_BEARER_TOKEN'"
  fi
  
  curl_cmd="$curl_cmd $url"
  
  echo -n "  $service on $host ($hostname:$port)... "
  
  if eval "$curl_cmd" > /dev/null 2>&1; then
    echo "✓ OK"
    return 0
  else
    echo "✗ FAILED"
    if [ "$VERBOSE" == "true" ]; then
      echo "    URL: $url"
      eval "$curl_cmd" 2>&1 | sed 's/^/    /' || true
    fi
    return 1
  fi
}

# Get hosts to check
if [ -n "$FILTER_HOST" ]; then
  HOSTS="$FILTER_HOST"
else
  HOSTS=$(yq '.hosts | keys | .[]' "$HOSTS_FILE")
fi

echo "=== AI Infrastructure Health Check ==="
echo ""

TOTAL=0
FAILED=0

for host in $HOSTS; do
  hostname=$(yq ".hosts.$host.hostname" "$HOSTS_FILE")
  
  if [ "$hostname" == "null" ]; then
    echo "Error: Host '$host' not found in hosts.yaml"
    continue
  fi
  
  echo "$host ($hostname):"
  
  # Get roles for this host
  roles=$(yq ".hosts.$host.roles[]" "$HOSTS_FILE")
  
  for role in $roles; do
    # Get service info
    port=$(yq ".services.$role.port" "$HOSTS_FILE")
    healthz=$(yq ".services.$role.healthz" "$HOSTS_FILE")
    requires_auth=$(yq ".services.$role.requires_auth" "$HOSTS_FILE")
    
    if [ "$port" == "null" ]; then
      echo "  Warning: Service '$role' not defined in hosts.yaml services section"
      continue
    fi
    
    TOTAL=$((TOTAL + 1))
    
    if ! check_service "$host" "$hostname" "$role" "$port" "$healthz" "$requires_auth"; then
      FAILED=$((FAILED + 1))
    fi
  done
  
  echo ""
done

echo "========================================"
echo "Summary: $((TOTAL - FAILED))/$TOTAL services healthy"

if [ $FAILED -eq 0 ]; then
  echo "✓ All services are healthy"
  exit 0
else
  echo "✗ $FAILED service(s) failed health check"
  exit 1
fi
