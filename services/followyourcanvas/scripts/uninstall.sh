#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  echo "ERROR: FollowYourCanvas systemd scripts are Linux-only." >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./uninstall.sh)." >&2
  exit 1
fi

systemctl disable --now followyourcanvas || true
rm -f /etc/systemd/system/followyourcanvas.service
systemctl daemon-reload

echo "FollowYourCanvas service removed. Runtime data remains in /var/lib/followyourcanvas." >&2
