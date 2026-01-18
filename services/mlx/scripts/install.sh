#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: mlx launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil
require_cmd python3

LABEL="com.mlx.openai.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
MLX_USER="${MLX_USER:-mlx}"
MLX_VENV="${MLX_VENV:-/var/lib/mlx/env}"
MLX_PIP_PACKAGES="${MLX_PIP_PACKAGES:-mlx-openai-server}"

# Runtime dirs expected by the plist/env
sudo mkdir -p /var/lib/mlx/{cache,run} /var/log/mlx

if ! id -u "${MLX_USER}" >/dev/null 2>&1; then
  echo "ERROR: user '${MLX_USER}' does not exist on this machine" >&2
  echo "Hint: create it (or set MLX_USER / update the plist UserName and chown targets)." >&2
  exit 1
fi

sudo chown -R "${MLX_USER}":staff /var/lib/mlx /var/log/mlx
sudo chmod 750 /var/lib/mlx /var/log/mlx

# Ensure the MLX OpenAI server entrypoint exists.
# If the executable referenced by the plist is missing, `launchctl bootstrap` fails with:
#   Bootstrap failed: 5: Input/output error
if [[ ! -x "${MLX_VENV}/bin/mlx-openai-server" ]]; then
  echo "MLX: provisioning venv at ${MLX_VENV}..." >&2
  sudo -u "${MLX_USER}" python3 -m venv "${MLX_VENV}"
  sudo -u "${MLX_USER}" "${MLX_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel

  echo "MLX: installing packages: ${MLX_PIP_PACKAGES}" >&2
  # shellcheck disable=SC2086
  sudo -u "${MLX_USER}" "${MLX_VENV}/bin/python" -m pip install --upgrade ${MLX_PIP_PACKAGES}

  if [[ ! -x "${MLX_VENV}/bin/mlx-openai-server" ]]; then
    echo "ERROR: mlx-openai-server not found after install." >&2
    echo "Hint: set MLX_PIP_PACKAGES to a valid package list for your setup." >&2
    echo "  Example: MLX_PIP_PACKAGES='mlx-openai-server mlx-lm'" >&2
    exit 1
  fi
fi

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

# Validate plist parses as XML property list
sudo plutil -lint "$DST" >/dev/null

# Reload service
sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$DST" || {
  echo "ERROR: launchctl bootstrap failed for ${LABEL}." >&2
  echo "Diagnostics:" >&2
  echo "  plist: ${DST}" >&2
  echo "  entrypoint: ${MLX_VENV}/bin/mlx-openai-server" >&2
  sudo ls -la "${MLX_VENV}/bin" 2>/dev/null | sed 's/^/  /' >&2 || true
  echo "  Try: sudo launchctl print system/${LABEL}" >&2
  exit 1
}
sudo launchctl kickstart -k system/"$LABEL"
