#!/usr/bin/env bash
set -euo pipefail

FILTER_HOST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      FILTER_HOST="$2"
      shift 2
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

run_restart() {
  local role="$1"
  local script="${ROOT}/${role}/scripts/restart.sh"
  if [[ -x "$script" ]]; then
    printf "==== %s ====\n" "$role" >&2
    "$script"
  fi
}

run_restart_remote() {
  local host_key="$1"
  local hostname="$2"
  local role="$3"

  local remote_base="${AI_INFRA_REMOTE_BASE:-~/ai}"
  local remote_ai_infra_root="${remote_base%/}/ai-infra"

  ssh "$hostname" "cd ${remote_ai_infra_root}/services/${role} && ./scripts/restart.sh"
}

echo "Restarting services for this host..." >&2

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

  echo "=== restart (remote) ${FILTER_HOST} (${hostname}) ===" >&2
  for role in $roles; do
    printf "==== %s ====\n" "$role" >&2
    run_restart_remote "$FILTER_HOST" "$hostname" "$role"
  done
  echo "Done." >&2
  exit 0
fi

if [[ -f "$HOSTS_FILE" ]] && command -v yq >/dev/null 2>&1; then
  current_hostname="$(hostname 2>/dev/null || echo '')"
  host_key="$(yq -r --arg hn "$current_hostname" '.hosts | to_entries[] | select(.value.hostname == $hn) | .key' "$HOSTS_FILE" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$host_key" ]]; then
    roles="$(yq -r ".hosts.${host_key}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
    for role in $roles; do
      run_restart "$role"
    done
    echo "Done." >&2
    exit 0
  fi
fi

# Fallback: try known roles.
run_restart "nexa"
run_restart "ollama"
run_restart "mlx"
run_restart "gateway"
echo "Done." >&2
