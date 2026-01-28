#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Linux" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now sdxl-turbo.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/sdxl-turbo.service
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    echo "✓ sdxl-turbo service disabled/stopped (systemd)" >&2
    echo "NOTE: runtime directories remain in /var/lib/sdxl-turbo and /var/log/sdxl-turbo." >&2
    exit 0
  fi
  echo "ERROR: systemctl not found; cannot uninstall/disable sdxl-turbo service." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
