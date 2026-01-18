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

# Keep runtime dirs writable by the service user.
sudo chown -R "${MLX_USER}":staff /var/lib/mlx/cache /var/lib/mlx/run /var/log/mlx
sudo chmod 750 /var/lib/mlx/cache /var/lib/mlx/run /var/log/mlx

# Keep the venv root-owned for system launchd jobs.
# For LaunchDaemons, launchd may refuse to bootstrap jobs whose ProgramArguments
# executable lives in a user-writable location or isn't owned by root.
sudo mkdir -p "${MLX_VENV}"
sudo chown -R root:wheel "${MLX_VENV}"
sudo chmod -R go-w "${MLX_VENV}"

# Ensure the MLX OpenAI server entrypoint exists.
# If the executable referenced by the plist is missing, `launchctl bootstrap` fails with:
#   Bootstrap failed: 5: Input/output error
if [[ ! -x "${MLX_VENV}/bin/mlx-openai-server" ]]; then
  echo "MLX: provisioning venv at ${MLX_VENV} (as root)..." >&2
  sudo python3 -m venv "${MLX_VENV}"
  sudo "${MLX_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel

  echo "MLX: installing packages: ${MLX_PIP_PACKAGES}" >&2
  # shellcheck disable=SC2086
  sudo "${MLX_VENV}/bin/python" -m pip install --upgrade ${MLX_PIP_PACKAGES}
fi

# Ensure the entrypoint isn't group/world writable and is root-owned.
sudo chown root:wheel "${MLX_VENV}/bin/mlx-openai-server" 2>/dev/null || true
sudo chmod 755 "${MLX_VENV}/bin/mlx-openai-server" 2>/dev/null || true
sudo chmod -R go-w "${MLX_VENV}" 2>/dev/null || true

if [[ ! -x "${MLX_VENV}/bin/mlx-openai-server" ]]; then
  echo "ERROR: mlx-openai-server not found at ${MLX_VENV}/bin/mlx-openai-server" >&2
  echo "Hint: set MLX_PIP_PACKAGES to a valid package list for your setup." >&2
  echo "  Example: MLX_PIP_PACKAGES='mlx-openai-server mlx-lm'" >&2
  exit 1
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
