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

quote_sh() {
  local s="$1"
  s=${s//\'/\'"\'"\'}
  printf "'%s'" "$s"
}

ssh_login_exec() {
  local hostname="$1"
  local remote_os="$2"
  local cmd="$3"

  local q
  if [[ "$remote_os" == "ubuntu" || "$remote_os" == "linux" ]]; then
    cmd="if [ -f ~/.profile ]; then . ~/.profile; fi; ${cmd}"
  fi
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
  echo "Set AI_INFRA_BASE in your dotfiles (login shell), or set AI_INFRA_REMOTE_BASE on the calling machine." >&2
  exit 2
}
EOF
}

remote_resolve_gateway_root_snippet() {
  cat <<'EOF'
resolve_gateway_root() {
  if [ -n "${AI_INFRA_BASE:-}" ]; then
    # Allow AI_INFRA_BASE to be either the repos base dir OR a sibling/child that implies the base.
    if [ -d "${AI_INFRA_BASE}/app" ] && [ -d "${AI_INFRA_BASE}/.git" ]; then
      printf "%s" "${AI_INFRA_BASE}"
      return 0
    fi
    if [ -d "${AI_INFRA_BASE}/gateway" ]; then
      printf "%s/gateway" "${AI_INFRA_BASE}"
      return 0
    fi
    if [ "$(basename "${AI_INFRA_BASE}")" = "ai-infra" ] && [ -d "$(dirname "${AI_INFRA_BASE}")/gateway" ]; then
      printf "%s/gateway" "$(dirname "${AI_INFRA_BASE}")"
      return 0
    fi
  fi
  for base in "$HOME" "$HOME/ai" "$HOME/src" "$HOME/repos" "$HOME/workspace" "$HOME/work"; do
    if [ -d "$base/gateway" ]; then
      printf "%s/gateway" "$base"
      return 0
    fi
  done

  for parent in "$HOME/code" "$HOME/Code"; do
    if [ -d "$parent/gateway" ]; then
      printf "%s/gateway" "$parent"
      return 0
    fi
    if [ -d "$parent" ]; then
      for d in "$parent"/*; do
        [ -d "$d/gateway" ] || continue
        printf "%s/gateway" "$d"
        return 0
      done
    fi
  done
  return 1
}

GATEWAY_ROOT="$(resolve_gateway_root)" || {
  echo "ERROR: could not locate gateway repo on this host." >&2
  echo "Set AI_INFRA_BASE in your dotfiles (login shell), or set AI_INFRA_REMOTE_BASE on the calling machine." >&2
  exit 2
}
EOF
}

remote_try_resolve_gateway_root_snippet() {
  cat <<'EOF'
resolve_gateway_root() {
  if [ -n "${AI_INFRA_BASE:-}" ]; then
    if [ -d "${AI_INFRA_BASE}/app" ] && [ -d "${AI_INFRA_BASE}/.git" ]; then
      printf "%s" "${AI_INFRA_BASE}"
      return 0
    fi
    if [ -d "${AI_INFRA_BASE}/gateway" ]; then
      printf "%s/gateway" "${AI_INFRA_BASE}"
      return 0
    fi
    if [ "$(basename "${AI_INFRA_BASE}")" = "ai-infra" ] && [ -d "$(dirname "${AI_INFRA_BASE}")/gateway" ]; then
      printf "%s/gateway" "$(dirname "${AI_INFRA_BASE}")"
      return 0
    fi
  fi
  for base in "$HOME" "$HOME/ai" "$HOME/src" "$HOME/repos" "$HOME/workspace" "$HOME/work"; do
    if [ -d "$base/gateway" ]; then
      printf "%s/gateway" "$base"
      return 0
    fi
  done

  for parent in "$HOME/code" "$HOME/Code"; do
    if [ -d "$parent/gateway" ]; then
      printf "%s/gateway" "$parent"
      return 0
    fi
    if [ -d "$parent" ]; then
      for d in "$parent"/*; do
        [ -d "$d/gateway" ] || continue
        printf "%s/gateway" "$d"
        return 0
      done
    fi
  done
  return 1
}

GATEWAY_ROOT="$(resolve_gateway_root)" || {
  echo "NOTE: gateway repo not found on this host; skipping gateway update." >&2
  exit 0
}
EOF
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
  local remote_os="$3"
  local role="$4"
  remote_os="${remote_os:-linux}"

  local remote_ai_infra_root=""
  if [[ -n "${AI_INFRA_REMOTE_BASE:-}" ]]; then
    local remote_base="${AI_INFRA_REMOTE_BASE}"
    remote_ai_infra_root="${remote_base%/}/ai-infra"
  else
    remote_ai_infra_root=""
  fi

  if [[ -n "$remote_ai_infra_root" ]]; then
    ssh_login_exec "$hostname" "$remote_os" "cd ${remote_ai_infra_root}/services/${role} && ./scripts/restart.sh"
  else
    ssh_login_exec "$hostname" "$remote_os" "$(remote_resolve_ai_infra_root_snippet)
cd \"\${AI_INFRA_ROOT}/services/${role}\" && ./scripts/restart.sh"
  fi
}

remote_git_pull() {
  local hostname="$1"
  local remote_os="$2"
  local remote_ai_infra_root=""
  local remote_gateway_root=""
  if [[ -n "${AI_INFRA_REMOTE_BASE:-}" ]]; then
    local remote_base="${AI_INFRA_REMOTE_BASE}"
    remote_ai_infra_root="${remote_base%/}/ai-infra"
    remote_gateway_root="${remote_base%/}/gateway"
  else
    remote_ai_infra_root=""
    remote_gateway_root=""
  fi

  if [[ "$GIT_PULL" == "true" ]]; then
    echo "Updating ai-infra on ${hostname}..." >&2
    if [[ -n "$remote_ai_infra_root" ]]; then
      ssh_login_exec "$hostname" "$remote_os" "cd ${remote_ai_infra_root} && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
    else
      ssh_login_exec "$hostname" "$remote_os" "$(remote_resolve_ai_infra_root_snippet)
cd \"\${AI_INFRA_ROOT}\" && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
    fi
  fi

  if [[ "$GIT_PULL_GATEWAY" == "true" ]]; then
    echo "Updating gateway on ${hostname}..." >&2
    if [[ -n "$remote_gateway_root" ]]; then
      ssh_login_exec "$hostname" "$remote_os" "cd ${remote_gateway_root} && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
    else
      ssh_login_exec "$hostname" "$remote_os" "$(remote_try_resolve_gateway_root_snippet)
cd \"\${GATEWAY_ROOT}\" && git checkout main >/dev/null 2>&1 || true; git pull --ff-only"
    fi
  fi
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
  remote_os="$(yq -r ".hosts.${FILTER_HOST}.os" "$HOSTS_FILE" 2>/dev/null || true)"
  if [[ -z "$hostname" || "$hostname" == "null" ]]; then
    echo "ERROR: host '$FILTER_HOST' not found in hosts.yaml" >&2
    exit 1
  fi
  if [[ -z "$remote_os" || "$remote_os" == "null" ]]; then
    remote_os="linux"
  fi
  roles="$(yq -r ".hosts.${FILTER_HOST}.roles[]" "$HOSTS_FILE" 2>/dev/null || true)"
  if [[ -z "$roles" ]]; then
    echo "ERROR: no roles defined for host '$FILTER_HOST'" >&2
    exit 1
  fi

  remote_git_pull "$hostname" "$remote_os"
  echo "=== restart (remote) ${FILTER_HOST} (${hostname}) ===" >&2
  for role in $roles; do
    printf "==== %s ====\n" "$role" >&2
    run_restart_remote "$FILTER_HOST" "$hostname" "$remote_os" "$role"
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
