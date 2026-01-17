#!/usr/bin/env bash
set -euo pipefail

# Restart InvokeAI + the OpenAI Images shim on Ubuntu (systemd).

SUDO=""
if [[ "${EUID:-0}" -ne 0 ]]; then
  SUDO="sudo"
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found; cannot restart services" >&2
  exit 1
fi

echo "Restarting invokeai..." >&2
$SUDO systemctl restart invokeai

echo "Restarting invokeai-openai-images-shim..." >&2
$SUDO systemctl restart invokeai-openai-images-shim

sleep 3

echo "Done." >&2
