#!/usr/bin/env bash
set -euo pipefail

MODEL="${NEXA_PULL_MODEL:-NexaAI/sdxl-turbo}"
NEXA_USER="${NEXA_USER:-nexa}"
NEXA_FORCE_PULL_MODEL="${NEXA_FORCE_PULL_MODEL:-0}"
CURRENT_USER="$(id -un 2>/dev/null || echo unknown)"

if ! command -v nexa >/dev/null 2>&1; then
  echo "ERROR: nexa not found in PATH" >&2
  exit 1
fi

list_contains_model() {
  local user="$1"

  nexa_as_user() {
    if [[ -n "${user}" ]] && [[ "${user}" == "${CURRENT_USER}" ]]; then
      nexa "$@"
      return
    fi

    if [[ -n "${user}" ]] && id -u "${user}" >/dev/null 2>&1; then
      sudo -u "${user}" env HOME=/var/lib/nexa nexa "$@"
      return
    fi

    nexa "$@"
  }

  # Best-effort: use the known-good command for this CLI.
  # If we can't list, return 1 (unknown) so we fall back to pulling.
  if nexa_as_user list >/dev/null 2>&1; then
    # Some CLIs print tables / unicode / formatting; search combined output.
    nexa_as_user list 2>&1 | tr -d '\r' | grep -Fq -- "${MODEL}" && return 0
  fi

  return 1
}

pull_as_user() {
  local user="$1"
  if [[ -n "${user}" ]] && [[ "${user}" == "${CURRENT_USER}" ]]; then
    nexa pull "${MODEL}"
    return
  fi

  if [[ -n "${user}" ]] && id -u "${user}" >/dev/null 2>&1; then
    sudo -u "${user}" env HOME=/var/lib/nexa nexa pull "${MODEL}"
    return
  fi

  if [[ -n "${user}" ]]; then
    echo "NOTE: user '${user}' not found; pulling as current user" >&2
  fi
  nexa pull "${MODEL}"
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
