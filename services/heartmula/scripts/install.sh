#!/usr/bin/env bash
set -euo pipefail

# Optional debug mode: set HEARTMULA_DEBUG=true to enable shell tracing
if [[ "${HEARTMULA_DEBUG:-}" == "true" ]]; then
  set -x
fi

# Better diagnostics on failure
trap 'rc=$?; cmd="${BASH_COMMAND:-}"; if [[ "$rc" -ne 0 ]]; then echo "ERROR: command failed: ${cmd} (exit ${rc})" >&2; fi' ERR


require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    echo "Hint: install or add to PATH (e.g. brew install $1)" >&2
    exit 1
  fi
}

echo "HeartMula: verifying host and required commands..." >&2
if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: heartmula launchd scripts are macOS-only." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil
require_cmd python3

echo "HeartMula: verified macOS and required commands" >&2

# Verify Python version early to avoid building heavy native deps like numpy
if [[ "${SKIP_PYTHON_VERSION_CHECK:-}" != "true" ]]; then
  PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "${PY_VER}" != "3.10" && "${PY_VER}" != "3.11" && "${PY_VER}" != "3.12" ]]; then
    echo "ERROR: Unsupported Python version: ${PY_VER}" >&2
    echo "HeartMuLa recommends Python 3.10/3.11 (some builds work on 3.12)." >&2
    echo "Options to proceed:" >&2
    echo "  - Install Python 3.10 and re-run: brew install python@3.10" >&2
    echo "  - Or install Xcode Command Line Tools and build deps (xcode-select --install; brew install openblas pkg-config)" >&2
    echo "  - To force continuation anyway, set SKIP_PYTHON_VERSION_CHECK=true and rerun (not recommended)" >&2
    exit 1
  fi
fi



LABEL="com.heartmula.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
HEARTMULA_USER="${HEARTMULA_USER:-heartmula}"
HEARTMULA_GROUP="${HEARTMULA_GROUP:-staff}"
HEARTMULA_HOME="${HEARTMULA_HOME:-/var/lib/heartmula}"
HEARTMULA_VENV="${HEARTMULA_VENV:-${HEARTMULA_HOME}/env}"
HEARTMULA_PIP_PACKAGES="${HEARTMULA_PIP_PACKAGES:-git+https://github.com/HeartMuLa/heartlib.git soundfile numpy}"
HEARTMULA_ENTRYPOINT="${HEARTMULA_ENTRYPOINT:-${HEARTMULA_VENV}/bin/python}"

ensure_service_user() {
  local user="$1"
  local group="$2"
  local home="$3"

  if id -u "${user}" >/dev/null 2>&1; then
    return 0
  fi

  require_cmd dscl

  if ! dscl . -read "/Groups/${group}" >/dev/null 2>&1; then
    echo "ERROR: group '${group}' not found on this machine" >&2
    exit 1
  fi

  local gid
  gid="$(dscl . -read "/Groups/${group}" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
  if [[ -z "${gid:-}" ]]; then
    echo "ERROR: failed to resolve gid for group '${group}'" >&2
    exit 1
  fi

  pick_free_uid() {
    local cand

    # Start at 501 (standard first non-system user on macOS) and use id -nu to check
    cand=501
    local limit=6000
    while [[ "${cand}" -le "${limit}" ]]; do
      if id -nu "${cand}" >/dev/null 2>&1; then
        cand=$((cand + 1))
        continue
      fi
      echo "${cand}"
      return 0
    done

    echo "ERROR: unable to find a free UID in range 501..${limit}" >&2
    return 1
  }

  local uid
  uid="$(pick_free_uid)"
  if [[ -z "${uid:-}" ]]; then
    echo "ERROR: unable to find a free UID for user '${user}'" >&2
    exit 1
  fi

  sudo mkdir -p "${home}"

  sudo dscl . -create "/Users/${user}"
  sudo dscl . -create "/Users/${user}" UserShell /bin/bash
  sudo dscl . -create "/Users/${user}" RealName "heartmula service user"
  sudo dscl . -create "/Users/${user}" UniqueID "${uid}"
  sudo dscl . -create "/Users/${user}" PrimaryGroupID "${gid}"
  sudo dscl . -create "/Users/${user}" NFSHomeDirectory "${home}"
  sudo dscl . -create "/Users/${user}" Password '*'
  # Hide service account from macOS login UI
  sudo dscl . -create "/Users/${user}" IsHidden 1 || true

  sudo dscl . -append "/Groups/${group}" GroupMembership "${user}" >/dev/null 2>&1 || true
}

# Create the service user early so directory ownership is correct from the start.
ensure_service_user "${HEARTMULA_USER}" "${HEARTMULA_GROUP}" "${HEARTMULA_HOME}"

sudo mkdir -p "${HEARTMULA_HOME}"/{cache,models,run} /var/log/heartmula

sudo chown -R "${HEARTMULA_USER}":"${HEARTMULA_GROUP}" "${HEARTMULA_HOME}" /var/log/heartmula
sudo chmod 750 "${HEARTMULA_HOME}" /var/log/heartmula

sudo mkdir -p "${HEARTMULA_VENV}"
sudo chown -R root:wheel "${HEARTMULA_VENV}"
sudo chmod -R go-w "${HEARTMULA_VENV}"

if [[ ! -x "${HEARTMULA_ENTRYPOINT}" ]]; then
  echo "HeartMula: provisioning venv at ${HEARTMULA_VENV} (as root)..." >&2
  sudo python3 -m venv "${HEARTMULA_VENV}"
  sudo "${HEARTMULA_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel

  echo "HeartMula: installing packages: ${HEARTMULA_PIP_PACKAGES}" >&2
  # shellcheck disable=SC2086

  # Try to preinstall numpy binary wheel to avoid costly builds from source
  echo "HeartMula: attempting to install numpy binary wheels (try newer versions first)..." >&2
  NUMPY_VERSIONS="${HEARTMULA_NUMPY_VERSIONS:-2.1.3 2.1.2 2.1.1 2.1.0 2.0.3 2.0.2}"
  installed_npy=""
  for v in $NUMPY_VERSIONS; do
    echo "HeartMula: attempting numpy==$v (binary)" >&2
    if sudo "${HEARTMULA_VENV}/bin/python" -m pip install --only-binary=:all: --upgrade "numpy==${v}"; then
      echo "HeartMula: numpy wheel ${v} installed successfully" >&2
      installed_npy="${v}"
      break
    else
      echo "HeartMula: numpy==$v wheel not available or failed; trying next..." >&2
    fi
  done

  if [[ -z "${installed_npy}" ]]; then
    echo "WARN: no numpy binary wheel succeeded; falling back to full package install (may require Xcode CLI and BLAS libs)" >&2
    echo "Hint: install Xcode CLI and BLAS libs: xcode-select --install; brew install openblas pkg-config" >&2
  fi

  sudo "${HEARTMULA_VENV}/bin/python" -m pip install --upgrade ${HEARTMULA_PIP_PACKAGES}

  # Copy the HeartMula server script
  echo "HeartMula: copying server script..." >&2
  sudo cp "${HERE}/../heartmula_server.py" "${HEARTMULA_HOME}/"
  sudo chown "${HEARTMULA_USER}":"${HEARTMULA_GROUP}" "${HEARTMULA_HOME}/heartmula_server.py"
  sudo chmod 755 "${HEARTMULA_HOME}/heartmula_server.py"
fi

sudo chown root:wheel "${HEARTMULA_ENTRYPOINT}" 2>/dev/null || true
sudo chmod 755 "${HEARTMULA_ENTRYPOINT}" 2>/dev/null || true
sudo chmod -R go-w "${HEARTMULA_VENV}" 2>/dev/null || true

if [[ ! -x "${HEARTMULA_ENTRYPOINT}" ]] || [[ ! -f "${HEARTMULA_HOME}/heartmula_server.py" ]]; then
  echo "ERROR: heartmula entrypoint not found at ${HEARTMULA_ENTRYPOINT} or server script missing" >&2
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