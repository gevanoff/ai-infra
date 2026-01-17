#!/bin/bash
# Deploy the stack (all hosts or one host) and then run functional verification.
#
# Usage:
#   ./deploy-and-verify.sh --token <gateway_token>
#   ./deploy-and-verify.sh --check-images --token <gateway_token>
#   ./deploy-and-verify.sh --host ai2 --token <gateway_token>
#
# Notes:
# - Deployment uses deploy-all.sh / deploy-host.sh.
# - After deployment, this script restarts any roles that do not have a deploy.sh (e.g. ollama/mlx/nexa).
# - Verification uses verify-stack.sh.
# - Gateway checks require an auth token (env GATEWAY_BEARER_TOKEN or --token), but only when the target hosts include the gateway role.

set -euo pipefail

FILTER_HOST=""
CHECK_IMAGES=false
VERBOSE=false
TOKEN="${GATEWAY_BEARER_TOKEN:-}"
TIMEOUT_SEC=""
NO_ROLE_RESTARTS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      FILTER_HOST="$2"
      shift 2
      ;;
    --check-images)
      CHECK_IMAGES=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --no-role-restarts)
      NO_ROLE_RESTARTS=true
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

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

quote_sh() {
  local s="$1"
  s=${s//\'/\'"\'"\'}
  printf "'%s'" "$s"
}

ssh_login_exec() {
  local hostname="$1"
  local remote_os="$2"
  local cmd="$3"

  # On Ubuntu/Linux, ensure ~/.profile is loaded (bash -lc can be affected by local dotfile patterns).
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

remote_resolve_ai_infra_root_snippet() {
  cat <<'EOF'
resolve_ai_infra_root() {
  if [ -n "${AI_INFRA_BASE:-}" ]; then
    # Allow AI_INFRA_BASE to be either the repos base dir OR the ai-infra repo root.
    if [ -d "${AI_INFRA_BASE}/services" ] && [ -d "${AI_INFRA_BASE}/.git" ]; then
      printf "%s" "${AI_INFRA_BASE}"
      return 0
    fi
    if [ -d "${AI_INFRA_BASE}/ai-infra" ]; then
      printf "%s/ai-infra" "${AI_INFRA_BASE}"
      return 0
    fi
  fi
  for base in "$HOME" "$HOME/ai" "$HOME/src" "$HOME/repos" "$HOME/workspace" "$HOME/work"; do
    if [ -d "$base/ai-infra" ]; then
      printf "%s/ai-infra" "$base"
      return 0
    fi
  done

  for parent in "$HOME/code" "$HOME/Code"; do
    if [ -d "$parent/ai-infra" ]; then
      printf "%s/ai-infra" "$parent"
      return 0
    fi
    if [ -d "$parent" ]; then
      for d in "$parent"/*; do
        [ -d "$d/ai-infra" ] || continue
        printf "%s/ai-infra" "$d"
        return 0
      done
    fi
  done
  return 1
}

AI_INFRA_ROOT="$(resolve_ai_infra_root)" || {
  echo "ERROR: could not locate ai-infra repo on this host." >&2
  echo "Set AI_INFRA_BASE in your dotfiles, or set AI_INFRA_REMOTE_BASE on the calling machine." >&2
  exit 2
}
EOF
}

target_hosts() {
  if [[ -n "$FILTER_HOST" ]]; then
    echo "$FILTER_HOST"
  else
    yq '.hosts | keys | .[]' "$HOSTS_FILE"
  fi
}

host_has_role() {
  local host="$1"
  local role="$2"
  yq -r ".hosts.${host}.roles[]" "$HOSTS_FILE" 2>/dev/null | grep -qx "$role"
}

restart_role_remote() {
  local host="$1"
  local hostname="$2"
  local remote_os="$3"
  local role="$4"

  ssh_login_exec "$hostname" "$remote_os" "$(remote_resolve_ai_infra_root_snippet)
cd \"\${AI_INFRA_ROOT}/services/${role}\" && ./scripts/restart.sh"
}

post_deploy_role_restarts() {
  if [[ "$NO_ROLE_RESTARTS" == "true" ]]; then
    echo "(skipping role restarts: --no-role-restarts)" >&2
    return 0
  fi

  echo "=== Post-deploy restarts (roles without deploy.sh) ==="

  local hosts
  hosts="$(target_hosts)"

  for host in $hosts; do
    local hostname remote_os roles
    hostname="$(yq -r ".hosts.${host}.hostname" "$HOSTS_FILE" 2>/dev/null || true)"
    remote_os="$(yq -r ".hosts.${host}.os" "$HOSTS_FILE" 2>/dev/null || true)"
    if [[ -z "$remote_os" || "$remote_os" == "null" ]]; then
      remote_os="linux"
    fi
    roles="$(yq -r ".hosts.${host}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
    if [[ -z "$hostname" || "$hostname" == "null" || -z "$roles" ]]; then
      echo "NOTE: skipping unknown/empty host '${host}'" >&2
      continue
    fi

    local did_any=false
    for role in $roles; do
      local deploy_script="$REPO_ROOT/services/${role}/scripts/deploy.sh"
      local restart_script="$REPO_ROOT/services/${role}/scripts/restart.sh"

      # If role has a deploy.sh, assume it handled restart already.
      if [[ -f "$deploy_script" ]]; then
        continue
      fi
      if [[ ! -x "$restart_script" ]]; then
        continue
      fi

      if [[ "$did_any" == "false" ]]; then
        echo "${host} (${hostname}):"
        did_any=true
      fi

      echo "  restarting ${role}..." >&2
      if ! restart_role_remote "$host" "$hostname" "$remote_os" "$role"; then
        echo "  NOTE: restart failed for ${role} on ${host}" >&2
      fi
    done

    if [[ "$did_any" == "false" && "$VERBOSE" == "true" ]]; then
      echo "${host} (${hostname}): (no role restarts needed)" >&2
    fi
  done

  echo ""
}

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "ERROR: hosts.yaml not found at $HOSTS_FILE" >&2
  exit 1
fi

ensure_yq
require_cmd ssh

# If we are verifying any gateway role, ensure a token is available up front.
if [[ -z "$TOKEN" ]]; then
  any_gateway=false
  for h in $(target_hosts); do
    if host_has_role "$h" gateway; then
      any_gateway=true
      break
    fi
  done
  if [[ "$any_gateway" == "true" ]]; then
    echo "ERROR: gateway token missing (set GATEWAY_BEARER_TOKEN or pass --token)" >&2
    exit 2
  fi
fi

deploy_ok=true
verify_ok=true

echo "=== Deploy ==="
if [[ -n "$FILTER_HOST" ]]; then
  if "$SCRIPT_DIR/deploy-host.sh" "$FILTER_HOST"; then
    echo "✓ deploy-host OK ($FILTER_HOST)"
  else
    echo "✗ deploy-host FAILED ($FILTER_HOST)" >&2
    deploy_ok=false
  fi
else
  if "$SCRIPT_DIR/deploy-all.sh"; then
    echo "✓ deploy-all OK"
  else
    echo "✗ deploy-all FAILED" >&2
    deploy_ok=false
  fi
fi

echo ""
if [[ "$deploy_ok" == "true" ]]; then
  post_deploy_role_restarts || true
else
  echo "NOTE: deploy reported failures; skipping post-deploy role restarts" >&2
  echo ""
fi

echo ""
echo "=== Verify ==="
VERIFY_ARGS=()

if [[ -n "$FILTER_HOST" ]]; then
  VERIFY_ARGS+=( --host "$FILTER_HOST" )
fi
if [[ "$CHECK_IMAGES" == "true" ]]; then
  VERIFY_ARGS+=( --check-images )
fi
if [[ "$VERBOSE" == "true" ]]; then
  VERIFY_ARGS+=( --verbose )
fi
if [[ -n "$TOKEN" ]]; then
  VERIFY_ARGS+=( --token "$TOKEN" )
fi
if [[ -n "$TIMEOUT_SEC" ]]; then
  VERIFY_ARGS+=( --timeout "$TIMEOUT_SEC" )
fi

if "$SCRIPT_DIR/verify-stack.sh" "${VERIFY_ARGS[@]}"; then
  echo "✓ verify-stack OK"
else
  echo "✗ verify-stack FAILED" >&2
  verify_ok=false
fi

if [[ "$deploy_ok" == "true" && "$verify_ok" == "true" ]]; then
  exit 0
fi
exit 1
