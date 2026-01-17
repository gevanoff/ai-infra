#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  LABEL="com.ollama.server"
  sudo launchctl print system/"$LABEL" | sed -n '1,220p'
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl status --no-pager ollama || true
    echo "---- /api/tags ----"
    if command -v curl >/dev/null 2>&1; then
      curl -sf --max-time 5 http://127.0.0.1:11434/api/tags | head -c 2000 || true
      echo ""
    else
      echo "NOTE: curl not found; skipping /api/tags check" >&2
    fi
    exit 0
  fi
  echo "ERROR: systemctl not found; cannot check ollama service status." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
