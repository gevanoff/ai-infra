#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat deploy is macOS-only." >&2
  exit 1
fi

resolve_src_dir() {
  if [[ -n "${LIBRECHAT_SRC_DIR:-}" ]]; then
    echo "${LIBRECHAT_SRC_DIR}"
    return 0
  fi

  if [[ -n "${AI_INFRA_BASE:-}" ]]; then
    if [[ -d "${AI_INFRA_BASE}/librechat" ]]; then echo "${AI_INFRA_BASE}/librechat"; return 0; fi
    if [[ -d "${AI_INFRA_BASE}/LibreChat" ]]; then echo "${AI_INFRA_BASE}/LibreChat"; return 0; fi
  fi

  for base in "$HOME" "$HOME/ai" "$HOME/src" "$HOME/repos" "$HOME/workspace" "$HOME/work"; do
    if [[ -d "$base/librechat" ]]; then echo "$base/librechat"; return 0; fi
    if [[ -d "$base/LibreChat" ]]; then echo "$base/LibreChat"; return 0; fi
  done

  return 1
}

git_safe_pull() {
  local repo="$1"
  local label="$2"
  local mode="${AI_INFRA_GIT_DIRTY_MODE:-stash}"
  cd "$repo" || return 1
  git checkout main >/dev/null 2>&1 || true
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    if [[ "$mode" == "discard" ]]; then
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 2
  }
}

require_cmd git
require_cmd rsync
require_cmd node
require_cmd npm
require_cmd curl

PORT="${LIBRECHAT_PORT:-3080}"

SRC_DIR=""
if SRC_DIR="$(resolve_src_dir)"; then
  :
else
  SRC_DIR="${AI_INFRA_BASE:-$HOME/ai}/librechat"
fi

LIBRECHAT_GIT_URL="${LIBRECHAT_GIT_URL:-https://github.com/danny-avila/LibreChat.git}"

if [[ -d "${SRC_DIR}/.git" ]]; then
  echo "Updating LibreChat source at ${SRC_DIR}..." >&2
  git_safe_pull "$SRC_DIR" "librechat"
elif [[ -d "${SRC_DIR}" && -n "$(ls -A "${SRC_DIR}" 2>/dev/null)" ]]; then
  echo "ERROR: ${SRC_DIR} exists but is not a git repo; refusing to overwrite" >&2
  exit 2
else
  echo "Cloning LibreChat into ${SRC_DIR}..." >&2
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$LIBRECHAT_GIT_URL" "$SRC_DIR"
fi

echo "Deploying LibreChat into /var/lib/librechat/app..." >&2
sudo mkdir -p /var/lib/librechat/app
sudo rsync -a --delete \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude '.env' \
  --exclude 'librechat.yaml' \
  "$SRC_DIR/" \
  /var/lib/librechat/app/

sudo chown -R librechat:staff /var/lib/librechat/app

# Ensure npm cache is service-owned. This prevents EACCES when the invoking user
# has a root-owned ~/.npm cache from prior npm versions.
sudo mkdir -p /var/lib/librechat/npm-cache
sudo chown -R librechat:staff /var/lib/librechat/npm-cache

echo "Installing Node dependencies (npm ci)..." >&2
sudo -u librechat env HOME=/var/lib/librechat NPM_CONFIG_CACHE=/var/lib/librechat/npm-cache bash -lc 'cd /var/lib/librechat/app && npm ci'

echo "Building frontend (npm run frontend)..." >&2
sudo -u librechat env HOME=/var/lib/librechat NPM_CONFIG_CACHE=/var/lib/librechat/npm-cache bash -lc 'cd /var/lib/librechat/app && npm run frontend'

echo "Restarting services..." >&2
"$(cd "$(dirname "$0")" && pwd)"/restart.sh

echo "Waiting for LibreChat /health..." >&2
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "OK" >&2
    exit 0
  fi
  sleep 1
done

echo "ERROR: LibreChat did not become healthy on http://127.0.0.1:${PORT}/health" >&2
exit 1
