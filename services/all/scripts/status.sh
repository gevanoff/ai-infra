#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HOSTS_FILE="${REPO_ROOT}/hosts.yaml"

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
