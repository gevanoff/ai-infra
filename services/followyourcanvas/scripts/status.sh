#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  echo "ERROR: FollowYourCanvas systemd scripts are Linux-only." >&2
  exit 1
fi

systemctl status followyourcanvas --no-pager
