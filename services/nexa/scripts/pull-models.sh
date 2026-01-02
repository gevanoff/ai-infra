#!/bin/zsh
set -euo pipefail

MODEL="${NEXA_PULL_MODEL:-NexaAI/sdxl-turbo}"
NEXA_USER="${NEXA_USER:-nexa}"

if ! command -v nexa >/dev/null 2>&1; then
  echo "ERROR: nexa not found in PATH" >&2
  exit 1
fi

# Pull as the service user so artifacts land under /var/lib/nexa (HOME in the plist).
if id -u "${NEXA_USER}" >/dev/null 2>&1; then
  sudo -u "${NEXA_USER}" env HOME=/var/lib/nexa nexa pull "${MODEL}"
else
  echo "NOTE: user '${NEXA_USER}' not found; pulling as current user" >&2
  nexa pull "${MODEL}"
fi
