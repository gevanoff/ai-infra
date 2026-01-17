#!/usr/bin/env bash
set -euo pipefail

# Status for InvokeAI + the OpenAI Images shim on Ubuntu (systemd).

SUDO=""
if [[ "${EUID:-0}" -ne 0 ]]; then
  SUDO="sudo"
fi

echo "==== invokeai (systemd) ===="
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl status --no-pager invokeai || true
  echo ""
  $SUDO systemctl status --no-pager invokeai-openai-images-shim || true
else
  echo "ERROR: systemctl not found; cannot show service status" >&2
  exit 1
fi

echo ""
echo "==== nginx/invokeai health ===="
if command -v curl >/dev/null 2>&1; then
  curl -sf --max-time 5 http://127.0.0.1:7860/healthz >/dev/null 2>&1 && echo "✓ /healthz OK" || echo "✗ /healthz FAILED"
  curl -sf --max-time 5 http://127.0.0.1:7860/readyz  >/dev/null 2>&1 && echo "✓ /readyz OK"  || echo "(readyz not OK)"
else
  echo "NOTE: curl not found; skipping HTTP checks" >&2
fi
