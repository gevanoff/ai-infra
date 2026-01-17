#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HOSTS_FILE="${REPO_ROOT}/hosts.yaml"

run_install() {
  local role="$1"
  local script="${ROOT}/${role}/scripts/install.sh"
  if [[ -x "$script" ]]; then
    printf "==== %s ====\n" "$role" >&2
    "$script"
  fi
}

echo "Installing services for this host..." >&2

if [[ -f "$HOSTS_FILE" ]] && command -v yq >/dev/null 2>&1; then
  current_hostname="$(hostname 2>/dev/null || echo '')"
  host_key="$(yq -r --arg hn "$current_hostname" '.hosts | to_entries[] | select(.value.hostname == $hn) | .key' "$HOSTS_FILE" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$host_key" ]]; then
    roles="$(yq -r ".hosts.${host_key}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
    for role in $roles; do
      run_install "$role"
    done
    echo "Done." >&2
    exit 0
  fi
fi

# Fallback: try known roles.
run_install "nexa"
run_install "ollama"
run_install "mlx"
run_install "gateway"
echo "Done." >&2
