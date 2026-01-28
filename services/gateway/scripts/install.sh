#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: gateway launchd scripts are macOS-only." >&2
  echo "Hint: run install on the macOS host, or use deploy-host.sh for cross-host operations." >&2
  exit 1
fi

require_cmd launchctl
require_cmd plutil

LABEL="com.ai.gateway"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"
VENV_PY="/var/lib/gateway/env/bin/python"
GATEWAY_VENV="${GATEWAY_VENV:-/var/lib/gateway/env}"
RECREATE_VENV=0
REQ1="/var/lib/gateway/app/app/requirements.txt"
REQ2="/var/lib/gateway/app/app/requirements.freeze.txt"
TOOLS_REQ="/var/lib/gateway/app/tools/requirements.txt"

usage() {
  cat <<EOF
Usage: $0 [--recreate-venv]

Installs/updates the gateway launchd plist and Python environment.

Flags:
  --recreate-venv   Delete and recreate ${GATEWAY_VENV} (useful if python version is too new and PyYAML can't install).

Env:
  GATEWAY_RECREATE_VENV=1   Same as --recreate-venv.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate-venv)
      RECREATE_VENV=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${GATEWAY_RECREATE_VENV:-}" == "1" ]]; then
  RECREATE_VENV=1
fi

# Runtime dirs expected by the gateway
sudo mkdir -p /var/lib/gateway/{app,data,tools} /var/lib/gateway/data/tools /var/log/gateway

if ! id -u gateway >/dev/null 2>&1; then
  echo "ERROR: user 'gateway' does not exist on this machine" >&2
  echo "Hint: create it (or change the plist UserName/chown targets)." >&2
  exit 1
fi

# Keep runtime dirs writable by the service user.
sudo chown -R gateway:staff /var/lib/gateway/app /var/lib/gateway/data /var/lib/gateway/tools /var/log/gateway
sudo chmod -R u+rwX,g+rX,o-rwx /var/lib/gateway/app /var/lib/gateway/data /var/lib/gateway/tools /var/log/gateway

# Keep the venv root-owned for system launchd jobs.
# For LaunchDaemons, launchd may refuse to bootstrap jobs whose ProgramArguments
# executable lives in a user-writable location or isn't owned by root.
sudo mkdir -p "${GATEWAY_VENV}"
sudo chown -R root:wheel "${GATEWAY_VENV}"
sudo chmod -R go-w "${GATEWAY_VENV}"

# Ensure a venv exists (used by the plist)
if [[ "${RECREATE_VENV}" == "1" && -d "${GATEWAY_VENV}" ]]; then
  echo "Recreating gateway venv at ${GATEWAY_VENV}..." >&2
  sudo launchctl bootout system/"${LABEL}" 2>/dev/null || true
  sudo rm -rf "${GATEWAY_VENV}"
fi

if [[ ! -x "${VENV_PY}" ]]; then
  # Prefer a stable Python version. Very new/preview versions can cause
  # dependency install failures (e.g., PyYAML wheels not available yet).
  PY_BOOTSTRAP=""
  for cand in python3.12 python3.11 python3.10 python3; do
    if command -v "${cand}" >/dev/null 2>&1; then
      PY_BOOTSTRAP="${cand}"
      break
    fi
  done
  if [[ -z "${PY_BOOTSTRAP}" ]]; then
    echo "ERROR: python3 not found (needed to create /var/lib/gateway/env venv)" >&2
    exit 1
  fi
  echo "Creating gateway venv with ${PY_BOOTSTRAP}..." >&2
  sudo "${PY_BOOTSTRAP}" -m venv "${GATEWAY_VENV}"
  sudo "${VENV_PY}" -m pip install -U pip >/dev/null
  sudo chown -R root:wheel "${GATEWAY_VENV}"
  sudo chmod -R go-w "${GATEWAY_VENV}"
fi

# Install Python deps if the gateway code has already been deployed.
# (We intentionally do not require deploy to have run before install.)
REQ_FILE=""
if [[ -f "${REQ1}" ]]; then
  REQ_FILE="${REQ1}"
elif [[ -f "${REQ2}" ]]; then
  REQ_FILE="${REQ2}"
fi

if [[ -n "${REQ_FILE}" ]]; then
  echo "Installing gateway Python dependencies from ${REQ_FILE}..." >&2
  sudo "${VENV_PY}" -m pip install -r "${REQ_FILE}"

  # Sanity check: required at import-time by app/backends.py
  if ! sudo "${VENV_PY}" -c "import yaml" >/dev/null 2>&1; then
    echo "ERROR: PyYAML is not importable in ${GATEWAY_VENV}." >&2
    echo "Diag: ${VENV_PY} -V => $(sudo "${VENV_PY}" -V 2>&1 || true)" >&2
    echo "Hint: set GATEWAY_RECREATE_VENV=1 (or pass --recreate-venv) to rebuild the venv with python3.12." >&2
    exit 1
  fi
else
  echo "NOTE: requirements not found at ${REQ1} or ${REQ2}; skipping pip install." >&2
  echo "Hint: run the gateway deploy script to populate /var/lib/gateway/app, then rerun install.sh." >&2
fi

# Install optional tool-script deps (e.g. OpenAI SDK streaming sanity check)
if [[ -f "${TOOLS_REQ}" ]]; then
  echo "Installing gateway tool-script dependencies from ${TOOLS_REQ}..." >&2
  sudo "${VENV_PY}" -m pip install -r "${TOOLS_REQ}"
fi

# Seed .env if missing (do NOT overwrite if it exists)
ENV_EXAMPLE="${HERE}/../env/gateway.env.example"
ENV_DST="/var/lib/gateway/app/.env"
if [[ ! -f "${ENV_DST}" && -f "${ENV_EXAMPLE}" ]]; then
  sudo cp "${ENV_EXAMPLE}" "${ENV_DST}"
  sudo chown gateway:staff "${ENV_DST}"
  sudo chmod 640 "${ENV_DST}"
  echo "NOTE: seeded ${ENV_DST} from gateway.env.example; set GATEWAY_BEARER_TOKEN." >&2
fi

# Even if the env file already existed, ensure the service user can read it.
# This commonly breaks if an operator edited it with sudo (root-owned, unreadable).
if [[ -f "${ENV_DST}" ]]; then
  sudo chown gateway:staff "${ENV_DST}"
  sudo chmod 640 "${ENV_DST}"
fi

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

# Validate plist parses as XML property list
sudo plutil -lint "$DST" >/dev/null

# If an env file exists, propagate selected TLS/backend envs into the plist
ENV_DST="/var/lib/gateway/app/.env"
PLISTBUDDY="/usr/libexec/PlistBuddy"
if [[ -f "${ENV_DST}" && -x "${PLISTBUDDY}" ]]; then
  echo "Propagating TLS/backend env vars from ${ENV_DST} into plist ${DST}"
  # Keys to copy into the plist EnvironmentVariables dict
  KEYS=(GATEWAY_TLS_CERT_PATH GATEWAY_TLS_KEY_PATH BACKEND_VERIFY_TLS BACKEND_CA_BUNDLE BACKEND_CLIENT_CERT)
  for k in "${KEYS[@]}"; do
    # extract the last assignment for the key (allow overrides)
    v=$(grep -E "^${k}=" "${ENV_DST}" | tail -n1 | sed -E 's/^'"${k}"'=//') || true
    if [[ -n "${v}" ]]; then
      # Remove any surrounding quotes
      v=$(echo "${v}" | sed -E 's/^"(.*)"$/\1/; s/^\x27(.*)\x27$/\1/')
      # Remove existing key if present, then add new string value
      "${PLISTBUDDY}" -c "Delete :EnvironmentVariables:${k}" "${DST}" 2>/dev/null || true
      "${PLISTBUDDY}" -c "Add :EnvironmentVariables:${k} string ${v}" "${DST}" || true
    fi
  done
fi

# Start now only if the deployed log config exists; otherwise leave installed.
LOGCFG="/var/lib/gateway/app/tools/uvicorn_log_config.json"
if [[ -f "${LOGCFG}" ]]; then
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootout system "$DST" 2>/dev/null || true

  if ! sudo launchctl bootstrap system "$DST"; then
    # On some macOS versions/configurations, bootstrap can return a generic I/O error
    # even if the job is already loaded. If the job exists, prefer idempotence.
    if sudo launchctl print system/"$LABEL" >/dev/null 2>&1; then
      echo "WARN: launchctl bootstrap failed for ${LABEL}, but job is already loaded; continuing." >&2
    else
      echo "ERROR: launchctl bootstrap failed for ${LABEL}." >&2
      echo "Diagnostics:" >&2
      echo "  plist: ${DST}" >&2
      echo "  venv python: ${VENV_PY}" >&2
      sudo ls -la "${GATEWAY_VENV}/bin" 2>/dev/null | sed 's/^/  /' >&2 || true
      if command -v log >/dev/null 2>&1; then
        echo "  recent launchd logs:" >&2
        sudo log show --last 2m --predicate 'process == "launchd"' --style compact 2>/dev/null | tail -n 40 | sed 's/^/  /' >&2 || true
      fi
      echo "  Try: sudo launchctl print system/${LABEL}" >&2
      exit 1
    fi
  fi

  sudo launchctl kickstart -k system/"$LABEL"
else
  echo "NOTE: ${LOGCFG} not found yet; plist installed but not started." >&2
  echo "Hint: run the gateway deploy script to populate /var/lib/gateway/app, then run scripts/restart.sh" >&2
fi
