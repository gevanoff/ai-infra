#!/bin/bash
# Pull models across the fleet, based on local manifests.
#
# Currently supported:
# - Ollama: pulls models listed in services/ollama/models/manifest.txt
#
# Usage:
#   ./pull-models.sh
#   ./pull-models.sh --host ai1
#   ./pull-models.sh --dry-run
#   ./pull-models.sh --verbose
#
# Notes:
# - For remote hosts, this uses SSH and runs `ollama pull <model>` on the target.
# - Requires yq for parsing hosts.yaml.

set -euo pipefail

VERBOSE=false
FILTER_HOST=""
DRY_RUN=false

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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOSTS_FILE="$REPO_ROOT/hosts.yaml"

OLLAMA_MANIFEST="$REPO_ROOT/services/ollama/models/manifest.txt"

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Error: hosts.yaml not found at $HOSTS_FILE" >&2
  exit 1
fi

# Ensure yq exists (same behavior as other scripts)
if ! command -v yq &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Installing yq..." >&2
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
  else
    echo "Error: yq is required but not installed." >&2
    echo "Install with: brew install yq (macOS)" >&2
    exit 1
  fi
fi

log() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "$*" >&2
  fi
}

trim_line() {
  # strip comments and whitespace
  local line="$1"
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  echo "$line"
}

read_manifest_models() {
  local manifest="$1"
  if [[ ! -f "$manifest" ]]; then
    return 0
  fi

  while IFS= read -r raw; do
    local line
    line="$(trim_line "$raw")"
    if [[ -n "$line" ]]; then
      echo "$line"
    fi
  done < "$manifest"
}

run_on_host() {
  local host="$1"
  local hostname="$2"
  shift 2

  local cmd=("$@")

  local current_host
  current_host=$(hostname 2>/dev/null || echo "")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN $host ($hostname): ${cmd[*]}"
    return 0
  fi

  if [[ "$current_host" == "$host" || "$current_host" == "$hostname" ]]; then
    log "Running locally: ${cmd[*]}"
    "${cmd[@]}"
    return $?
  fi

  log "Running remotely on $hostname: ${cmd[*]}"
  ssh "$hostname" "${cmd[*]}"
}

# Determine which hosts to operate on
if [[ -n "$FILTER_HOST" ]]; then
  HOSTS="$FILTER_HOST"
else
  HOSTS=$(yq '.hosts | keys | .[]' "$HOSTS_FILE")
fi

MODELS=$(read_manifest_models "$OLLAMA_MANIFEST" || true)

echo "=== Pull Models ==="
if [[ -z "$MODELS" ]]; then
  echo "No models listed in services/ollama/models/manifest.txt; nothing to pull."
  exit 0
fi

echo "Models:"
echo "$MODELS" | sed 's/^/  - /'
echo ""

FAILED=0

for host in $HOSTS; do
  hostname=$(yq ".hosts.$host.hostname" "$HOSTS_FILE")
  if [[ "$hostname" == "null" ]]; then
    echo "Warning: host '$host' not found in hosts.yaml" >&2
    continue
  fi

  roles=$(yq ".hosts.$host.roles[]" "$HOSTS_FILE" 2>/dev/null || true)
  has_ollama=false
  for role in $roles; do
    if [[ "$role" == "ollama" ]]; then
      has_ollama=true
      break
    fi
  done

  if [[ "$has_ollama" != "true" ]]; then
    log "Skipping $host ($hostname): no ollama role"
    continue
  fi

  echo "$host ($hostname):"

  # Ensure ollama exists on target (best-effort)
  if ! run_on_host "$host" "$hostname" command -v ollama >/dev/null 2>&1; then
    echo "  ✗ ollama not found on host" >&2
    FAILED=$((FAILED + 1))
    echo ""
    continue
  fi

  for model in $MODELS; do
    echo "  pulling: $model"
    if ! run_on_host "$host" "$hostname" ollama pull "$model"; then
      echo "  ✗ failed: $model" >&2
      FAILED=$((FAILED + 1))
    fi
  done

  echo ""
done

if [[ $FAILED -eq 0 ]]; then
  echo "✓ Model pull complete"
  exit 0
fi

echo "✗ Model pull finished with $FAILED failure(s)" >&2
exit 1
