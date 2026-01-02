#!/bin/zsh
set -euo pipefail

MODEL="${NEXA_PULL_MODEL:-NexaAI/sdxl-turbo}"
NEXA_USER="${NEXA_USER:-nexa}"
NEXA_FORCE_PULL_MODEL="${NEXA_FORCE_PULL_MODEL:-0}"

if ! command -v nexa >/dev/null 2>&1; then
  echo "ERROR: nexa not found in PATH" >&2
  exit 1
fi

list_contains_model() {
  local user="$1"

  nexa_as_user() {
    if [[ -n "${user}" ]] && id -u "${user}" >/dev/null 2>&1; then
      sudo -u "${user}" env HOME=/var/lib/nexa nexa "$@"
    else
      nexa "$@"
    fi
  }

  # Best-effort: try common list commands. If we can't list, return 1 (unknown).
  if nexa_as_user models list >/dev/null 2>&1; then
    nexa_as_user models list 2>/dev/null | grep -Fq -- "${MODEL}" && return 0
  fi

  if nexa_as_user list >/dev/null 2>&1; then
    nexa_as_user list 2>/dev/null | grep -Fq -- "${MODEL}" && return 0
  fi

  if nexa_as_user ls >/dev/null 2>&1; then
    nexa_as_user ls 2>/dev/null | grep -Fq -- "${MODEL}" && return 0
  fi

  return 1
}

pull_as_user() {
  local user="$1"
  if [[ -n "${user}" ]] && id -u "${user}" >/dev/null 2>&1; then
    sudo -u "${user}" env HOME=/var/lib/nexa nexa pull "${MODEL}"
  else
    if [[ -n "${user}" ]]; then
      echo "NOTE: user '${user}' not found; pulling as current user" >&2
    fi
    nexa pull "${MODEL}"
  fi
}

# Check first to avoid huge downloads when the model is already present.
if [[ "${NEXA_FORCE_PULL_MODEL}" == "1" ]]; then
  echo "NOTE: forcing model pull (NEXA_FORCE_PULL_MODEL=1): ${MODEL}" >&2
  pull_as_user "${NEXA_USER}"
  exit 0
fi

if list_contains_model "${NEXA_USER}" >/dev/null 2>&1; then
  echo "NOTE: model already present (skipping): ${MODEL}" >&2
  exit 0
fi

# Pull as the service user so artifacts land under /var/lib/nexa (HOME in the plist).
pull_as_user "${NEXA_USER}"
