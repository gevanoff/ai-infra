#!/usr/bin/env bash
set -euo pipefail

FILTER_HOST=""
GIT_PULL=false
GIT_PULL_GATEWAY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      FILTER_HOST="$2"
      shift 2
      ;;
    --git-pull)
      GIT_PULL=true
      shift
      ;;
    --git-pull-gateway)
      GIT_PULL_GATEWAY=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HOSTS_FILE="${REPO_ROOT}/hosts.yaml"

ensure_yq() {
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Installing yq..." >&2
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
    return 0
  fi
  echo "ERROR: yq is required but not installed." >&2
  echo "Install with: brew install yq (macOS)" >&2
  exit 1
}

ensure_ssh() {
  command -v ssh >/dev/null 2>&1 || {
    echo "ERROR: ssh not found in PATH" >&2
    exit 1
  }
}

run_status() {
  local role="$1"
  local script="${ROOT}/${role}/scripts/status.sh"
  if [[ -x "$script" ]]; then
    printf "==== %s ====\n" "$role"
    if ! "$script"; then
      echo "NOTE: ${role} status failed" >&2
    fi
    echo ""
  fi
}

run_status_remote() {
  local host_key="$1"
  local hostname="$2"
  local role="$3"

  local remote_ai_infra_root=""
  if [[ -n "${AI_INFRA_REMOTE_BASE:-}" ]]; then
    local remote_base="${AI_INFRA_REMOTE_BASE}"
    remote_ai_infra_root="${remote_base%/}/ai-infra"
  else
    # Evaluate AI_INFRA_BASE on the remote host (fallback to ~/ai).
    remote_ai_infra_root='"${AI_INFRA_BASE:-~/ai}"/ai-infra'
  fi

  # Assumes ai-infra is already present on the remote host (deploy-host.sh syncs it).
  ssh "$hostname" "cd ${remote_ai_infra_root}/services/${role} && ./scripts/status.sh"
}

remote_git_pull() {
  local hostname="$1"
  local remote_ai_infra_root=""
  local remote_gateway_root=""
  if [[ -n "${AI_INFRA_REMOTE_BASE:-}" ]]; then
    local remote_base="${AI_INFRA_REMOTE_BASE}"
    remote_ai_infra_root="${remote_base%/}/ai-infra"
    remote_gateway_root="${remote_base%/}/gateway"
  else
    remote_ai_infra_root='"${AI_INFRA_BASE:-~/ai}"/ai-infra'
    remote_gateway_root='"${AI_INFRA_BASE:-~/ai}"/gateway'
  fi

  if [[ "$GIT_PULL" == "true" ]]; then
    echo "Updating ai-infra on ${hostname}..." >&2
    ssh "$hostname" "cd ${remote_ai_infra_root} && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
  fi

  if [[ "$GIT_PULL_GATEWAY" == "true" ]]; then
    echo "Updating gateway on ${hostname}..." >&2
    ssh "$hostname" "cd ${remote_gateway_root} && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
  fi
}

if [[ -n "$FILTER_HOST" ]]; then
  if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "ERROR: hosts.yaml not found at $HOSTS_FILE" >&2
    exit 1
  fi
  ensure_yq
  ensure_ssh

  hostname="$(yq -r ".hosts.${FILTER_HOST}.hostname" "$HOSTS_FILE" 2>/dev/null || true)"
  if [[ -z "$hostname" || "$hostname" == "null" ]]; then
    echo "ERROR: host '$FILTER_HOST' not found in hosts.yaml" >&2
    exit 1
  fi
  roles="$(yq -r ".hosts.${FILTER_HOST}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
  if [[ -z "$roles" ]]; then
    echo "ERROR: no roles defined for host '$FILTER_HOST'" >&2
    exit 1
  fi

  remote_git_pull "$hostname"
  echo "=== status (remote) ${FILTER_HOST} (${hostname}) ==="
  for role in $roles; do
    printf "==== %s ====\n" "$role"
    if ! run_status_remote "$FILTER_HOST" "$hostname" "$role"; then
      echo "NOTE: ${role} status failed" >&2
    fi
    echo ""
  done
  exit 0
fi

# Prefer host-aware behavior when hosts.yaml + yq exist. Fall back to running everything.
if [[ -f "$HOSTS_FILE" ]] && command -v yq >/dev/null 2>&1; then
  current_hostname="$(hostname 2>/dev/null || echo '')"

  host_key="$(yq -r --arg hn "$current_hostname" '.hosts | to_entries[] | select(.value.hostname == $hn) | .key' "$HOSTS_FILE" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$host_key" ]]; then
    roles="$(yq -r ".hosts.${host_key}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
    for role in $roles; do
      run_status "$role"
    done
    exit 0
  fi
fi

# Fallback: run all known statuses but never hard-fail the wrapper.
run_status "nexa"
run_status "ollama"
run_status "mlx"
run_status "gateway"
