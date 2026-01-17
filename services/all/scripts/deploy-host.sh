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

# Get OS for this host (used for remote login shell selection)
REMOTE_OS=$(yq ".hosts.$HOST.os" "$HOSTS_FILE")
if [ "$REMOTE_OS" == "null" ] || [ -z "$REMOTE_OS" ]; then
  REMOTE_OS="linux"
fi

quote_sh() {
  # Single-quote a string for POSIX-ish shells.
  local s="$1"
  s=${s//\'/\'"\'"\'}
  printf "'%s'" "$s"
}

ssh_login_exec() {
  local hostname="$1"
  local remote_os="$2"
  local cmd="$3"

  # On Ubuntu/Linux, ensure ~/.profile is loaded.
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

resolve_remote_base() {
  # Prefer a local override; otherwise ask the remote host (login shell) for AI_INFRA_BASE.
  if [ -n "${AI_INFRA_REMOTE_BASE:-}" ]; then
    echo "$AI_INFRA_REMOTE_BASE"
    return 0
  fi
  ssh_login_exec "$HOSTNAME" "$REMOTE_OS" 'echo "${AI_INFRA_BASE:-$HOME/ai}"'
}

escape_dq() {
  # Escape for embedding inside a double-quoted string.
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf "%s" "$s"
}

git_origin_url() {
  local repo_dir="$1"
  git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true
}

ensure_remote_repo_cmd() {
  # Emit a remote-shell snippet that ensures a repo exists at $1 and is up-to-date.
  # Uses AI_INFRA_GIT_DIRTY_MODE=stash|discard behavior.
  local repo_dir="$1"
  local repo_url="$2"
  local label="$3"
  local repo_dir_esc repo_url_esc label_esc
  repo_dir_esc="$(escape_dq "$repo_dir")"
  repo_url_esc="$(escape_dq "$repo_url")"
  label_esc="$(escape_dq "$label")"

  printf 'set -e\nREPO_DIR="%s"\nREPO_URL="%s"\nLABEL="%s"\nDIRTY_MODE="%s"\n' \
    "$repo_dir_esc" \
    "$repo_url_esc" \
    "$label_esc" \
    "${AI_INFRA_GIT_DIRTY_MODE:-stash}"

  cat <<'EOF'

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required on this host to update $LABEL" >&2
  exit 2
fi

git_safe_pull() {
  local repo="$1"
  local label="$2"
  local mode="$3"
  cd "$repo" || return 1
  git checkout main >/dev/null 2>&1 || true
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    if [ "$mode" = "discard" ]; then
      echo "WARN: $label repo dirty; discarding local changes" >&2
      git reset --hard HEAD >/dev/null 2>&1 || true
      git clean -fd >/dev/null 2>&1 || true
    else
      echo "WARN: $label repo dirty; stashing local changes" >&2
      git stash push -u -m "ai-infra autostash $(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
    fi
  fi
  git pull --ff-only
}

if [ -d "$REPO_DIR/.git" ]; then
  echo "Updating $LABEL in $REPO_DIR..." >&2
  git_safe_pull "$REPO_DIR" "$LABEL" "$DIRTY_MODE"
elif [ -d "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
  echo "ERROR: $REPO_DIR exists but is not a git repo; refusing to overwrite" >&2
  exit 2
else
  if [ -z "$REPO_URL" ]; then
    echo "ERROR: missing origin URL for $LABEL; cannot clone" >&2
    exit 2
  fi
  echo "Cloning $LABEL into $REPO_DIR..." >&2
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
  git_safe_pull "$REPO_DIR" "$LABEL" "$DIRTY_MODE" || true
fi
EOF
}

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
  RESTART_SCRIPT="$SERVICE_DIR/scripts/restart.sh"
  
  if [ ! -f "$DEPLOY_SCRIPT" ]; then
    # Many roles (ollama/mlx) are managed via install/restart scripts and do not need a deploy step.
    if [ -f "$RESTART_SCRIPT" ]; then
      echo "No deploy script for ${role}; running restart instead."
    else
      echo "No deploy script for ${role}; skipping."
    fi

    CURRENT_HOST=$(hostname)
    if [ "$CURRENT_HOST" == "$HOST" ] || [ "$CURRENT_HOST" == "$HOSTNAME" ]; then
      if [ -f "$RESTART_SCRIPT" ]; then
        cd "$SERVICE_DIR"
        ./scripts/restart.sh || true
      fi
    else
      if [ -f "$RESTART_SCRIPT" ]; then
        REMOTE_BASE="$(resolve_remote_base | tr -d '\r' | tail -n 1)"
        if [ -z "$REMOTE_BASE" ]; then
          echo "Error: could not resolve remote base directory on $HOSTNAME" >&2
          echo "Hint: set AI_INFRA_REMOTE_BASE locally or AI_INFRA_BASE in remote dotfiles." >&2
          exit 1
        fi
        REMOTE_AI_INFRA_ROOT="${REMOTE_BASE%/}/ai-infra"

        AI_INFRA_URL="$(git_origin_url "$AI_INFRA_ROOT")"
        ensure_ai_infra_cmd="$(ensure_remote_repo_cmd "$REMOTE_AI_INFRA_ROOT" "$AI_INFRA_URL" "ai-infra")"
        ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "$ensure_ai_infra_cmd" || true

        ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "cd \"${REMOTE_AI_INFRA_ROOT}/services/$role\" && ./scripts/restart.sh" || true
      fi
    fi
    echo "✓ $role processed"
    echo ""
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

    # Remote repo layout:
    #   <remote_base>/ai-infra
    #   <remote_base>/gateway
    # remote_base comes from local AI_INFRA_REMOTE_BASE override, else remote AI_INFRA_BASE (login shell), else $HOME/ai.
    REMOTE_BASE="$(resolve_remote_base | tr -d '\r' | tail -n 1)"
    if [ -z "$REMOTE_BASE" ]; then
      echo "Error: could not resolve remote base directory on $HOSTNAME" >&2
      echo "Hint: set AI_INFRA_REMOTE_BASE locally or AI_INFRA_BASE in remote dotfiles." >&2
      exit 1
    fi
    REMOTE_AI_INFRA_ROOT="${REMOTE_BASE%/}/ai-infra"
    REMOTE_GATEWAY_ROOT="${REMOTE_BASE%/}/gateway"

    # Ensure remote base exists
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "mkdir -p \"${REMOTE_BASE}\"" || true

    # Update remote repos via git (no rsync into git-controlled directories).
    AI_INFRA_URL="$(git_origin_url "$AI_INFRA_ROOT")"
    ensure_ai_infra_cmd="$(ensure_remote_repo_cmd "$REMOTE_AI_INFRA_ROOT" "$AI_INFRA_URL" "ai-infra")"
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "$ensure_ai_infra_cmd"

    if [ "$role" == "gateway" ]; then
      GATEWAY_URL="${GATEWAY_ORIGIN_URL:-}"
      if [ -z "$GATEWAY_URL" ] && [ -d "$GATEWAY_ROOT/.git" ]; then
        GATEWAY_URL="$(git_origin_url "$GATEWAY_ROOT")"
      fi
      ensure_gateway_cmd="$(ensure_remote_repo_cmd "$REMOTE_GATEWAY_ROOT" "$GATEWAY_URL" "gateway")"
      ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "$ensure_gateway_cmd"
    fi

    # Then run the deploy script on the remote host
    ssh_login_exec "$HOSTNAME" "$REMOTE_OS" "cd \"${REMOTE_AI_INFRA_ROOT}/services/$role\" && ./scripts/deploy.sh"
  fi
  
  echo "✓ $role deployed"
  echo ""
done

echo "=== Deployment to $HOST complete ==="
