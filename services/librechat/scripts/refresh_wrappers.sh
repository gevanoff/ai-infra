#!/usr/bin/env bash
set -euo pipefail

# Regenerate root-owned wrapper scripts for node/mongod under /var/lib/librechat/bin.
# Useful if wrappers were created incorrectly or node/mongod moved.

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat wrapper refresh is macOS-only." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 2
  }
}

require_cmd sudo

DO_RESTART=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart)
      DO_RESTART=false
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  refresh_wrappers.sh [--no-restart]

Rewrites:
  /var/lib/librechat/bin/node
  /var/lib/librechat/bin/mongod

Then restarts launchd jobs unless --no-restart is given.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

find_first_existing() {
  for p in "$@"; do
    if [[ -z "$p" ]]; then
      continue
    fi

    # Never select our own wrappers as the source.
    if [[ "$p" == "/var/lib/librechat/bin/node" || "$p" == "/var/lib/librechat/bin/mongod" ]]; then
      continue
    fi

    if [[ -x "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

write_exec_wrapper() {
  local dst="$1"
  local target="$2"

  sudo tee "$dst" >/dev/null <<EOF
#!/bin/sh
exec "${target}" "\$@"
EOF
  sudo chown root:wheel "$dst"
  sudo chmod 755 "$dst"
}

bin_dir="/var/lib/librechat/bin"
sudo mkdir -p "$bin_dir"
sudo chown root:wheel "$bin_dir"
sudo chmod 755 "$bin_dir"

node_src="$(find_first_existing \
  /opt/homebrew/bin/node \
  /usr/local/bin/node \
  "$(command -v node 2>/dev/null || true)" \
)" || {
  echo "ERROR: node not found; install Node (brew install node)" >&2
  exit 2
}

mongod_src="$(find_first_existing \
  /opt/homebrew/bin/mongod \
  /opt/homebrew/opt/mongodb-community@8.0/bin/mongod \
  /opt/homebrew/opt/mongodb-community/bin/mongod \
  /usr/local/bin/mongod \
  "$(command -v mongod 2>/dev/null || true)" \
)" || {
  echo "ERROR: mongod not found; install MongoDB (brew install mongodb-community@8.0)" >&2
  exit 2
}

echo "Using node:   $node_src" >&2
echo "Using mongod: $mongod_src" >&2

write_exec_wrapper "$bin_dir/node" "$node_src"
write_exec_wrapper "$bin_dir/mongod" "$mongod_src"

echo "Wrote wrappers under $bin_dir" >&2

if [[ "$DO_RESTART" == "true" ]]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  "$here/restart.sh" >/dev/null
  echo "Restarted LibreChat + MongoDB via restart.sh" >&2
fi
