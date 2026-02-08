#!/usr/bin/env bash
set -euo pipefail

note() {
  echo "[invokeai] $*" >&2
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  note "ERROR: uninstall is Linux/systemd-only."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  note "ERROR: systemctl not found."
  exit 1
fi

SUDO=""
if [[ "$EUID" -ne 0 ]]; then
  SUDO="sudo"
fi

note "Stopping invokeai services..."
$SUDO systemctl disable --now invokeai.service invokeai-openai-images-shim.service >/dev/null 2>&1 || true

note "Removing systemd unit files..."
$SUDO rm -f /etc/systemd/system/invokeai.service /etc/systemd/system/invokeai-openai-images-shim.service
$SUDO systemctl daemon-reload

note "Removing nginx config (if present)..."
$SUDO rm -f /etc/nginx/sites-enabled/invokeai /etc/nginx/sites-enabled/invokeai.conf /etc/nginx/sites-available/invokeai

note "InvokeAI uninstall complete. Runtime data remains under /var/lib/invokeai."
