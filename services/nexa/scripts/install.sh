#!/bin/zsh
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This script targets macOS (launchd)." >&2
  echo "Hint: run it on the Mac host that runs launchd." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil
require_cmd curl
require_cmd pkgutil
require_cmd installer

LABEL="com.nexa.image.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
NEXA_USER="${NEXA_USER:-nexa}"

# Optional: install Nexa CLI if it's not present.
# Default URL is Apple Silicon (arm64). Override if needed.
NEXA_PKG_URL="${NEXA_PKG_URL:-https://public-storage.nexa4ai.com/nexa_sdk/downloads/nexa-cli_macos_arm64.pkg}"
NEXA_PKG_PATH="${NEXA_PKG_PATH:-/tmp/nexa-cli.pkg}"
NEXA_SKIP_PKG_INSTALL="${NEXA_SKIP_PKG_INSTALL:-0}"

if ! command -v nexa >/dev/null 2>&1; then
  if [[ "${NEXA_SKIP_PKG_INSTALL}" == "1" ]]; then
    echo "ERROR: nexa not found in PATH and NEXA_SKIP_PKG_INSTALL=1" >&2
    exit 1
  fi
  echo "Installing Nexa CLI from ${NEXA_PKG_URL} ..." >&2
  curl -L -o "${NEXA_PKG_PATH}" "${NEXA_PKG_URL}"
  pkgutil --check-signature "${NEXA_PKG_PATH}"
  sudo installer -pkg "${NEXA_PKG_PATH}" -target /
fi

if ! command -v sox >/dev/null 2>&1; then
  echo "NOTE: 'sox' not found. Nexa docs note it is required for some functionality." >&2
  echo "Hint: install via Homebrew (e.g. 'brew install sox') if needed." >&2
fi

# Runtime dirs expected by the plist.
sudo mkdir -p /var/lib/nexa /var/log/nexa

if ! id -u "${NEXA_USER}" >/dev/null 2>&1; then
  echo "ERROR: user '${NEXA_USER}' does not exist on this machine" >&2
  echo "Hint: create it (or set NEXA_USER / update the plist UserName and chown targets)." >&2
  exit 1
fi

sudo chown -R "${NEXA_USER}":staff /var/lib/nexa /var/log/nexa
sudo chmod 750 /var/lib/nexa /var/log/nexa

# Optional model pull (recommended). Can be skipped for faster installs.
NEXA_SKIP_PULL_MODEL="${NEXA_SKIP_PULL_MODEL:-0}"
if [[ "${NEXA_SKIP_PULL_MODEL}" != "1" ]]; then
  "${HERE}/pull-models.sh"
else
  echo "NOTE: skipping nexa model pull (NEXA_SKIP_PULL_MODEL=1)" >&2
fi

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

# Validate plist parses as XML property list
sudo plutil -lint "$DST" >/dev/null

# Reload service
sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$DST"
sudo launchctl kickstart -k system/"$LABEL"
