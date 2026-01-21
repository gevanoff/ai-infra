#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd systemctl

SERVICE="com.heartmula.server.service"
sudo systemctl --no-pager status "$SERVICE" | sed -n '1,220p'
