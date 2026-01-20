#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: heartmula launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil
require_cmd python3

LABEL="com.heartmula.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
HEARTMULA_USER="${HEARTMULA_USER:-heartmula}"
HEARTMULA_VENV="${HEARTMULA_VENV:-/var/lib/heartmula/env}"
HEARTMULA_PIP_PACKAGES="${HEARTMULA_PIP_PACKAGES:-heartmula}"
HEARTMULA_ENTRYPOINT="${HEARTMULA_ENTRYPOINT:-${HEARTMULA_VENV}/bin/heartmula}"

sudo mkdir -p /var/lib/heartmula/{cache,models,run} /var/log/heartmula

if ! id -u "${HEARTMULA_USER}" >/dev/null 2>&1; then
  echo "ERROR: user '${HEARTMULA_USER}' does not exist on this machine" >&2
  echo "Hint: create it (or set HEARTMULA_USER / update the plist UserName and chown targets)." >&2
  exit 1
fi

sudo chown -R "${HEARTMULA_USER}":staff /var/lib/heartmula /var/log/heartmula
sudo chmod 750 /var/lib/heartmula /var/log/heartmula

sudo mkdir -p "${HEARTMULA_VENV}"
sudo chown -R root:wheel "${HEARTMULA_VENV}"
sudo chmod -R go-w "${HEARTMULA_VENV}"

if [[ ! -x "${HEARTMULA_ENTRYPOINT}" ]]; then
  echo "HeartMula: provisioning venv at ${HEARTMULA_VENV} (as root)..." >&2
  sudo python3 -m venv "${HEARTMULA_VENV}"
  sudo "${HEARTMULA_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel

  echo "HeartMula: installing packages: ${HEARTMULA_PIP_PACKAGES}" >&2
  # shellcheck disable=SC2086
  sudo "${HEARTMULA_VENV}/bin/python" -m pip install --upgrade ${HEARTMULA_PIP_PACKAGES}
fi

sudo chown root:wheel "${HEARTMULA_ENTRYPOINT}" 2>/dev/null || true
sudo chmod 755 "${HEARTMULA_ENTRYPOINT}" 2>/dev/null || true
sudo chmod -R go-w "${HEARTMULA_VENV}" 2>/dev/null || true

if [[ ! -x "${HEARTMULA_ENTRYPOINT}" ]]; then
  echo "ERROR: heartmula entrypoint not found at ${HEARTMULA_ENTRYPOINT}" >&2
  echo "Hint: set HEARTMULA_PIP_PACKAGES or HEARTMULA_ENTRYPOINT to match your installation." >&2
  exit 1
fi

sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

sudo plutil -lint "$DST" >/dev/null

sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo launchctl bootout system "$DST" 2>/dev/null || true

if ! sudo launchctl bootstrap system "$DST"; then
  if sudo launchctl print system/"$LABEL" >/dev/null 2>&1; then
    echo "WARN: launchctl bootstrap failed for ${LABEL}, but job is already loaded; continuing." >&2
  else
    echo "ERROR: launchctl bootstrap failed for ${LABEL}." >&2
    echo "Diagnostics:" >&2
    echo "  plist: ${DST}" >&2
    echo "  entrypoint: ${HEARTMULA_ENTRYPOINT}" >&2
    sudo ls -la "${HEARTMULA_VENV}/bin" 2>/dev/null | sed 's/^/  /' >&2 || true
    if command -v log >/dev/null 2>&1; then
      echo "  recent launchd logs:" >&2
      sudo log show --last 2m --predicate 'process == "launchd"' --style compact 2>/dev/null | tail -n 40 | sed 's/^/  /' >&2 || true
    fi
    echo "  Try: sudo launchctl print system/${LABEL}" >&2
    exit 1
  fi
fi

sudo launchctl kickstart -k system/"$LABEL"
