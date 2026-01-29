#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This deploy script targets macOS (launchd)." >&2
  echo "Hint: run it on the Mac host that runs launchd for ${LAUNCHD_LABEL:-the gateway}." >&2
  exit 1
fi

require_cmd sudo
require_cmd rsync
require_cmd launchctl
require_cmd curl
require_cmd lsof
require_cmd sed
require_cmd tail

POST_DEPLOY_HOOK=0
GIT_UPDATE=0
GIT_REF=""

usage() {
  cat <<EOF
Usage: $0 [--post-deploy-hook]

Deploys the gateway repo into /var/lib/gateway/app and restarts launchd.

If the gateway source tree is a git repo, you can optionally force it to a
specific ref before deploying.

Flags:
  --post-deploy-hook   After a successful deploy, run freeze_release.sh then appliance_smoketest.sh.
  --git-update         If SRC_DIR is a git repo, fetch and hard-reset to --git-ref.
  --git-ref <ref>      Git ref to deploy when --git-update is set (default: origin/main).

Env:
  GATEWAY_POST_DEPLOY_HOOK=1   Same as --post-deploy-hook.
  GATEWAY_GIT_UPDATE=1         Same as --git-update.
  GATEWAY_GIT_REF=<ref>        Same as --git-ref.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-deploy-hook)
      POST_DEPLOY_HOOK=1
      shift
      ;;
    --git-update)
      GIT_UPDATE=1
      shift
      ;;
    --git-ref)
      GIT_REF="${2:-}"
      if [[ -z "${GIT_REF}" ]]; then
        echo "ERROR: --git-ref requires a value" >&2
        exit 2
      fi
      shift 2
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

if [[ "${GATEWAY_POST_DEPLOY_HOOK:-}" == "1" ]]; then
  POST_DEPLOY_HOOK=1
fi

if [[ "${GATEWAY_GIT_UPDATE:-}" == "1" ]]; then
  GIT_UPDATE=1
fi

# If the flag wasn't provided, allow env to set the ref.
if [[ -z "${GIT_REF}" && -n "${GATEWAY_GIT_REF:-}" ]]; then
  GIT_REF="${GATEWAY_GIT_REF}"
fi


# ---- config (edit if your labels/paths differ) ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"  # ai-infra/services/gateway
# Default AI_INFRA_ROOT to $HOME/ai/ai-infra unless overridden in environment. If that
# path doesn't exist, fall back to the script-relative location for backward
# compatibility.
AI_INFRA_ROOT="${AI_INFRA_ROOT:-${HOME}/ai/ai-infra}"
if [[ ! -d "${AI_INFRA_ROOT}" ]]; then
  AI_INFRA_ROOT="$(cd "${SERVICE_DIR}/../.." && pwd)"  # ai-infra (fallback)
fi

# Where to deploy FROM (the gateway app source tree)
# - Preferred: set GATEWAY_SRC_DIR to your local gateway checkout (env override)
# - Default:   $HOME/ai/gateway (common layout on ai hosts)
GATEWAY_SRC_DIR="${GATEWAY_SRC_DIR:-${HOME}/ai/gateway}"

SRC_DIR=""
for cand in \
  "${GATEWAY_SRC_DIR}" \
  "${AI_INFRA_ROOT}/gateway" \
  "${AI_INFRA_ROOT}/../gateway" \
  "${AI_INFRA_ROOT}/../../gateway" \
; do
  [[ -n "${cand}" ]] || continue
  if [[ -f "${cand}/app/main.py" ]]; then
    SRC_DIR="${cand}"
    break
  fi
done

if [[ -z "${SRC_DIR}" ]]; then
  echo "ERROR: Could not find gateway source tree (missing app/main.py)." >&2
  echo "Tried:" >&2
  echo "  - GATEWAY_SRC_DIR=${GATEWAY_SRC_DIR:-\"\"}" >&2
  echo "  - ${AI_INFRA_ROOT}/gateway" >&2
  echo "  - ${AI_INFRA_ROOT}/../gateway" >&2
  echo "  - ${AI_INFRA_ROOT}/../../gateway" >&2
  echo "Hint: clone the gateway repo under \\$HOME/ai/gateway or export GATEWAY_SRC_DIR=/path/to/your/gateway." >&2
  exit 1
fi

echo "AI_INFRA_ROOT: ${AI_INFRA_ROOT}"
echo "GATEWAY_SRC_DIR: ${GATEWAY_SRC_DIR}"
echo "Resolved Source: ${SRC_DIR}"

RUNTIME_ROOT="/var/lib/gateway"
APP_DIR="${RUNTIME_ROOT}/app"
TOOLS_DIR="${RUNTIME_ROOT}/tools"
LAUNCHD_LABEL="com.ai.gateway"
PLIST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
HEALTH_URL="https://127.0.0.1:8800/health"
PORT="8800"
LOG_DIR="/var/log/gateway"
ERR_LOG="${LOG_DIR}/gateway.err.log"
OUT_LOG="${LOG_DIR}/gateway.out.log"
PYTHON_BIN="${RUNTIME_ROOT}/env/bin/python"
CURL_CONNECT_TIMEOUT_SEC="1"
CURL_MAX_TIME_SEC="2"
CURL_TLS_ARGS=()
if [[ "${HEALTH_URL}" == https://* ]]; then
  if [[ "${GATEWAY_TLS_INSECURE:-}" == "1" || "${GATEWAY_TLS_INSECURE:-}" == "true" ]]; then
    CURL_TLS_ARGS=(--insecure)
  fi
fi

# ---- safety checks ----

if ! sudo test -d "${RUNTIME_ROOT}" 2>/dev/null; then
  echo "ERROR: runtime root ${RUNTIME_ROOT} does not exist (or is not accessible)" >&2
  echo "Hint: create it with: sudo mkdir -p ${RUNTIME_ROOT}" >&2
  exit 1
fi

echo "Source:  ${SRC_DIR}"
echo "Deploy:  ${APP_DIR}"
echo "Label:   ${LAUNCHD_LABEL}"

# Commit/ref we intend to deploy (best-effort). We capture this BEFORE rsync so
# the stamp always corresponds to the source snapshot we copied.
SRC_COMMIT_FOR_DEPLOY=""
SRC_REF_FOR_DEPLOY=""

if [[ -d "${SRC_DIR}/.git" ]]; then
  SRC_COMMIT="$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${SRC_COMMIT}" ]]; then
    echo "Source commit: ${SRC_COMMIT}"
  fi

  if [[ "${GIT_UPDATE}" == "1" ]]; then
    require_cmd git
    REF="${GIT_REF:-origin/main}"
    SRC_REF_FOR_DEPLOY="${REF}"
    echo "Updating gateway source repo to ${REF} (HARD RESET)..." >&2
    git -C "${SRC_DIR}" fetch --prune origin >&2
    git -C "${SRC_DIR}" checkout --detach "${REF}" >&2
    git -C "${SRC_DIR}" reset --hard "${REF}" >&2

    SRC_COMMIT="$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "${SRC_COMMIT}" ]]; then
      echo "Updated source commit: ${SRC_COMMIT}" >&2
    fi
  fi

  # The commit we will stamp into the deployed tree.
  SRC_COMMIT_FOR_DEPLOY="${SRC_COMMIT}"
fi

if ! id -u gateway >/dev/null 2>&1; then
  echo "ERROR: user 'gateway' does not exist on this machine" >&2
  echo "Hint: create it (or change chown target in this script)." >&2
  exit 1
fi

if ! sudo test -x "${PYTHON_BIN}" 2>/dev/null; then
  echo "ERROR: expected python not found/executable: ${PYTHON_BIN}" >&2
  echo "Hint: this can mean the venv is missing, or your user cannot traverse ${RUNTIME_ROOT}." >&2
  echo "Hint: run: services/gateway/scripts/install.sh (or install.sh --recreate-venv)" >&2
  exit 1
fi

# The repo layout is app/main.py, so the deployed entrypoint is ${APP_DIR}/app/main.py
if [[ ! -f "${SRC_DIR}/app/main.py" ]]; then
  echo "ERROR: expected source module not found at ${SRC_DIR}/app/main.py" >&2
  echo "Hint: repo layout changed? update the rsync source or the plist entrypoint." >&2
  exit 1
fi

# ---- ensure runtime layout expected by app ----
# main.py reads env from /var/lib/gateway/app/.env, uses /var/lib/gateway/tools, and writes /var/lib/gateway/data/memory.sqlite
sudo mkdir -p "${RUNTIME_ROOT}/data" "${TOOLS_DIR}"
sudo chown -R gateway:staff "${RUNTIME_ROOT}"
sudo chown -R gateway:staff "${RUNTIME_ROOT}/data" "${TOOLS_DIR}"
sudo chmod -R u+rwX,g+rX,o-rwx "${RUNTIME_ROOT}/data" "${TOOLS_DIR}"

# launchd won't create parent log directories; the plist points stdout/stderr into /var/log/gateway
sudo mkdir -p "${LOG_DIR}"
sudo chown -R gateway:staff "${LOG_DIR}"
sudo chmod -R u+rwX,g+rX,o-rwx "${LOG_DIR}"

# ---- deploy code (exclude runtime/state/dev noise) ----
# NOTE: trailing slashes matter: sync repo CONTENTS into app dir
sudo mkdir -p "${APP_DIR}"
sudo rsync -a --delete \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude '.DS_Store' \
  --exclude 'Library/' \
  --exclude '.env' --exclude '.env.*' \
  --exclude 'env/' --exclude '.venv/' --exclude 'venv/' \
  --exclude 'data/' --exclude '*.sqlite' --exclude '*.sqlite3' --exclude '*.db' --exclude '*.wal' --exclude '*.shm' \
  --exclude 'logs/' --exclude '*.log' \
  --exclude 'cache/' --exclude 'models/' --exclude 'huggingface/' --exclude 'hf_cache/' \
  "${SRC_DIR}/" "${APP_DIR}/"

# Explicitly ensure critical app files are copied (rsync may have excludes or issues)
MISSING_FILES=0
CRITICAL_FILES=(
  "app/tts_routes.py"
  "app/tts_backend.py"
  "app/backends.py"
  "app/health_checker.py"
  "app/model_aliases.py"
  "app/ui_routes.py"
)
for f in "${CRITICAL_FILES[@]}"; do
  SRCF="${SRC_DIR}/${f}"
  DSTF="${APP_DIR}/${f}"
  if [[ -f "${SRCF}" ]]; then
    sudo mkdir -p "$(dirname "${DSTF}")"
    if sudo cp -f "${SRCF}" "${DSTF}"; then
      sudo chown gateway:staff "${DSTF}" || true
      sudo chmod 644 "${DSTF}" || true
    else
      echo "WARNING: failed to copy ${f}" >&2
      MISSING_FILES=1
    fi
  else
    echo "WARNING: source missing, not deployed: ${f}" >&2
    MISSING_FILES=1
  fi
done
if [[ "${MISSING_FILES}" -eq 1 ]]; then
  echo "ERROR: One or more critical files failed to copy. See warnings above." >&2
  echo "---- missing critical files in deployed tree ----" >&2
  for f in "${CRITICAL_FILES[@]}"; do
    if [[ ! -f "${APP_DIR}/${f}" ]]; then
      echo "${APP_DIR}/${f}" >&2
    fi
  done
  exit 1
fi

# ---- permissions ----
sudo chown -R gateway:staff "${APP_DIR}"
sudo chmod -R u+rwX,g+rX,o-rwx "${APP_DIR}"

# Validate Python syntax for deployed modules (best-effort; fail deploy if syntax errors present)
PY_BAD=0
PY_VERSION=""
if PY_VERSION="$(sudo -H -u gateway "${PYTHON_BIN}" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)"; then
  echo "Gateway python: ${PY_VERSION}"
else
  echo "ERROR: unable to run ${PYTHON_BIN} as gateway user." >&2
  echo "Hint: check permissions on ${RUNTIME_ROOT}/env and the gateway user." >&2
  exit 1
fi

PY_MAJOR="${PY_VERSION%%.*}"
PY_MINOR="${PY_VERSION#*.}"
PY_MINOR="${PY_MINOR%%.*}"
if [[ -n "${PY_MAJOR}" && -n "${PY_MINOR}" ]]; then
  if [[ "${PY_MAJOR}" -lt 3 || ( "${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -lt 10 ) ]]; then
    echo "ERROR: gateway requires Python >= 3.10; found ${PY_VERSION} at ${PYTHON_BIN}." >&2
    echo "Hint: rerun services/gateway/scripts/install.sh --recreate-venv to rebuild with python3.12." >&2
    exit 1
  fi
fi

while IFS= read -r -d '' pyfile; do
  PY_ERR=""
  if ! PY_ERR="$(sudo -H -u gateway env PYTHONDONTWRITEBYTECODE=1 "${PYTHON_BIN}" -m py_compile "${pyfile}" 2>&1 >/dev/null)"; then
    echo "ERROR: python compile failed for ${pyfile}" >&2
    if [[ -n "${PY_ERR}" ]]; then
      echo "---- python error ----" >&2
      echo "${PY_ERR}" >&2
      echo "----------------------" >&2
    fi
    PY_BAD=1
  fi
done < <(find "${APP_DIR}/app" -name '*.py' -print0)
if [[ "${PY_BAD}" -eq 1 ]]; then
  echo "ERROR: python syntax check failed" >&2
  exit 1
fi

# The gateway reads required settings from /var/lib/gateway/app/.env.
# We exclude .env from rsync, so preserve it but ensure it is readable by the service user.
ENV_DST="${APP_DIR}/.env"
if [[ -f "${ENV_DST}" ]]; then
  sudo chown gateway:staff "${ENV_DST}"
  sudo chmod 640 "${ENV_DST}"
else
  echo "WARNING: ${ENV_DST} not found; gateway will not start without GATEWAY_BEARER_TOKEN." >&2
fi

# ---- install/update Python dependencies ----
echo "Installing Python dependencies..."
if [[ -f "${APP_DIR}/app/requirements.freeze.txt" ]]; then
  sudo -H -u gateway "${PYTHON_BIN}" -m pip install --quiet --no-warn-script-location -r "${APP_DIR}/app/requirements.freeze.txt"
  echo "Dependencies installed from app/requirements.freeze.txt"

  # Sanity check: required at import-time by app/backends.py
  if ! sudo -H -u gateway "${PYTHON_BIN}" -c "import yaml" >/dev/null 2>&1; then
    echo "ERROR: PyYAML is not importable in ${PYTHON_BIN} environment." >&2
    echo "Hint: Python version may be too new for prebuilt wheels; recreate /var/lib/gateway/env with python3.12." >&2
    sudo "${PYTHON_BIN}" -V 2>&1 || true
    exit 1
  fi
else
  echo "WARNING: app/requirements.freeze.txt not found, skipping dependency install" >&2
fi

# ---- stamp deployed commits (best-effort) ----
# These files allow generating a release manifest later without requiring git.
if [[ -n "${SRC_COMMIT_FOR_DEPLOY}" ]]; then
  echo "${SRC_COMMIT_FOR_DEPLOY}" | sudo tee "${APP_DIR}/DEPLOYED_GATEWAY_COMMIT" >/dev/null || true
fi

if [[ -n "${SRC_REF_FOR_DEPLOY}" ]]; then
  echo "${SRC_REF_FOR_DEPLOY}" | sudo tee "${APP_DIR}/DEPLOYED_GATEWAY_GIT_REF" >/dev/null || true
fi

if command -v git >/dev/null 2>&1 && [[ -d "${AI_INFRA_ROOT}/.git" ]]; then
  AI_INFRA_COMMIT="$(git -C "${AI_INFRA_ROOT}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${AI_INFRA_COMMIT}" ]]; then
    echo "${AI_INFRA_COMMIT}" | sudo tee "${APP_DIR}/DEPLOYED_AI_INFRA_COMMIT" >/dev/null || true
  fi
fi

# Make helper scripts executable (best-effort; non-fatal).
sudo mkdir -p "${APP_DIR}/tools"
if [[ -f "${SRC_DIR}/tools/openai_sdk_stream_test.py" ]]; then
  # Explicitly copy (some operators customize rsync excludes; this guarantees the file lands).
  sudo cp "${SRC_DIR}/tools/openai_sdk_stream_test.py" "${APP_DIR}/tools/openai_sdk_stream_test.py" || true
  sudo chmod 755 "${APP_DIR}/tools/openai_sdk_stream_test.py" || true

  # Convenience: provide a stable path under /var/lib/gateway/tools as well.
  # /var/lib/gateway/tools is the tool sandbox/working directory, but people often look for scripts there.
  sudo ln -sf "${APP_DIR}/tools/openai_sdk_stream_test.py" "${TOOLS_DIR}/openai_sdk_stream_test.py" || true
fi

if [[ -f "${SRC_DIR}/tools/verify_gateway.py" ]]; then
  # Explicitly copy (some operators customize rsync excludes; this guarantees the file lands).
  sudo cp "${SRC_DIR}/tools/verify_gateway.py" "${APP_DIR}/tools/verify_gateway.py" || true
  sudo chmod 755 "${APP_DIR}/tools/verify_gateway.py" || true

  # Convenience: stable path under /var/lib/gateway/tools as well.
  sudo ln -sf "${APP_DIR}/tools/verify_gateway.py" "${TOOLS_DIR}/verify_gateway.py" || true
fi

if [[ -f "${AI_INFRA_ROOT}/services/heartmula/tools/heartmula_generate.py" ]]; then
  # Explicitly copy (some operators customize rsync excludes; this guarantees the file lands).
  sudo cp "${AI_INFRA_ROOT}/services/heartmula/tools/heartmula_generate.py" "${APP_DIR}/tools/heartmula_generate.py" || true
  sudo chmod 755 "${APP_DIR}/tools/heartmula_generate.py" || true

  # Convenience: stable path under /var/lib/gateway/tools as well.
  sudo ln -sf "${APP_DIR}/tools/heartmula_generate.py" "${TOOLS_DIR}/heartmula_generate.py" || true
fi

# Ensure new UI static assets are present even if rsync excludes vary.
# This explicitly installs the music UI so administrators who customize rsync still get it.
if [[ -f "${SRC_DIR}/app/static/music.html" ]]; then
  sudo cp "${SRC_DIR}/app/static/music.html" "${APP_DIR}/app/static/music.html" || true
  sudo chown gateway:staff "${APP_DIR}/app/static/music.html" || true
  sudo chmod 644 "${APP_DIR}/app/static/music.html" || true
fi
if [[ -f "${SRC_DIR}/app/static/music.js" ]]; then
  sudo cp "${SRC_DIR}/app/static/music.js" "${APP_DIR}/app/static/music.js" || true
  sudo chown gateway:staff "${APP_DIR}/app/static/music.js" || true
  sudo chmod 644 "${APP_DIR}/app/static/music.js" || true
fi

# Ensure important UI static assets (favicons, manifest, SVGs) are present
# even if operators customize rsync excludes.
STATIC_FILES=(
  "app/static/favicon.ico"
  "app/static/apple-touch-icon.png"
  "app/static/site.webmanifest"
  "app/static/safari-pinned-tab.svg"
  "app/static/browserconfig.xml"
  "app/static/ai-infra.png"
  "app/static/favicon-16.png"
  "app/static/favicon-32.png"
  "app/static/favicon-48.png"
  "app/static/favicon-64.png"
  "app/static/favicon-128.png"
  "app/static/favicon-180.png"
  "app/static/favicon-192.png"
  "app/static/favicon-512.png"
)
for f in "${STATIC_FILES[@]}"; do
  SRCF="${SRC_DIR}/${f}"
  DSTF="${APP_DIR}/${f}"
  if [[ -f "${SRCF}" ]]; then
    sudo mkdir -p "$(dirname "${DSTF}")"
    sudo cp -f "${SRCF}" "${DSTF}" || true
    sudo chown gateway:staff "${DSTF}" || true
    sudo chmod 644 "${DSTF}" || true
  fi
done

# ---- install model alias config (non-destructive) ----
# The gateway can load aliases from /var/lib/gateway/app/model_aliases.json.
# Only install the example template if no file exists yet.
ALIASES_DST="${APP_DIR}/model_aliases.json"
ALIASES_EXAMPLE_SRC="${SERVICE_DIR}/env/model_aliases.json.example"
if [[ ! -f "${ALIASES_DST}" && -f "${ALIASES_EXAMPLE_SRC}" ]]; then
  echo "Installing default model_aliases.json (template)"
  sudo cp "${ALIASES_EXAMPLE_SRC}" "${ALIASES_DST}"
fi

# ---- install tools registry config (non-destructive) ----
# The gateway can load tools from /var/lib/gateway/app/tools_registry.json.
# Only install the example template if no file exists yet.
TOOLS_REGISTRY_DST="${APP_DIR}/tools_registry.json"
TOOLS_REGISTRY_EXAMPLE_SRC="${SERVICE_DIR}/env/tools_registry.json.example"
if [[ ! -f "${TOOLS_REGISTRY_DST}" && -f "${TOOLS_REGISTRY_EXAMPLE_SRC}" ]]; then
  echo "Installing default tools_registry.json (template)"
  sudo cp "${TOOLS_REGISTRY_EXAMPLE_SRC}" "${TOOLS_REGISTRY_DST}"
fi

if [[ ! -f "${APP_DIR}/app/main.py" ]]; then
  echo "ERROR: deploy completed but ASGI module missing at ${APP_DIR}/app/main.py" >&2
  echo "Hint: check rsync excludes and that ${SRC_DIR}/app/main.py exists." >&2
  exit 1
fi

# ---- propagate TLS/backend envs into plist (so launchd picks them up) ----
# If an env file exists in the deployed app tree, copy selected keys into the
# installed plist so launchd will expose them to the gateway process.
PLISTBUDDY="/usr/libexec/PlistBuddy"
if [[ -f "${ENV_DST}" && -x "${PLISTBUDDY}" ]]; then
  echo "Propagating TLS/backend env vars from ${ENV_DST} into plist ${PLIST}"
  KEYS=(GATEWAY_TLS_CERT_PATH GATEWAY_TLS_KEY_PATH BACKEND_VERIFY_TLS BACKEND_CA_BUNDLE BACKEND_CLIENT_CERT PUBLIC_BASE_URL)
  for k in "${KEYS[@]}"; do
    v=$(grep -E "^${k}=" "${ENV_DST}" | tail -n1 | sed -E 's/^'"${k}"'=//') || true
    if [[ -n "${v}" ]]; then
      v=$(echo "${v}" | sed -E 's/^"(.*)"$/\1/; s/^\x27(.*)\x27$/\1/')
      sudo "${PLISTBUDDY}" -c "Delete :EnvironmentVariables:${k}" "${PLIST}" 2>/dev/null || true
      sudo "${PLISTBUDDY}" -c "Add :EnvironmentVariables:${k} string ${v}" "${PLIST}" || true
    fi
  done
  echo "Resulting plist EnvironmentVariables:"
  sudo "${PLISTBUDDY}" -c "Print :EnvironmentVariables" "${PLIST}" 2>/dev/null || true
fi

# If TLS cert is present but PUBLIC_BASE_URL not set in the plist, add a default
# so clients are encouraged to use HTTPS on ai2:8800.
if [[ -f "/etc/ssl/certs/server.crt" && -x "${PLISTBUDDY}" && -f "${PLIST}" ]]; then
  if ! sudo "${PLISTBUDDY}" -c "Print :EnvironmentVariables:PUBLIC_BASE_URL" "${PLIST}" >/dev/null 2>&1; then
    echo "Adding default PUBLIC_BASE_URL=https://ai2:8800 to ${PLIST}"
    sudo "${PLISTBUDDY}" -c "Add :EnvironmentVariables:PUBLIC_BASE_URL string https://ai2:8800" "${PLIST}" || true
  fi
fi

# ---- ensure installed plist contains SSL args + env vars, then restart service ----
# Ensure the installed plist (if present) contains the canonical ssl args and
# environment variables so launchd runs uvicorn with the expected cert/key.
PLISTBUDDY="/usr/libexec/PlistBuddy"
if [[ -f "${PLIST}" && -x "${PLISTBUDDY}" ]]; then
  # Quick check: only patch the plist when necessary (missing args/envs).
  need_patch=0

  # Check required ProgramArguments
  if ! sudo "${PLISTBUDDY}" -c "Print :ProgramArguments" "${PLIST}" 2>/dev/null | grep -q -- "--ssl-certfile"; then
    need_patch=1
  fi
  if ! sudo "${PLISTBUDDY}" -c "Print :ProgramArguments" "${PLIST}" 2>/dev/null | grep -q -- "--ssl-keyfile"; then
    need_patch=1
  fi

  # Check required EnvironmentVariables
  for _k in GATEWAY_TLS_CERT_PATH GATEWAY_TLS_KEY_PATH; do
    if ! sudo "${PLISTBUDDY}" -c "Print :EnvironmentVariables:${_k}" "${PLIST}" >/dev/null 2>&1; then
      need_patch=1
    fi
  done

  # If TLS cert exists, ensure PUBLIC_BASE_URL is present
  if [[ -f "/etc/ssl/certs/server.crt" ]]; then
    if ! sudo "${PLISTBUDDY}" -c "Print :EnvironmentVariables:PUBLIC_BASE_URL" "${PLIST}" >/dev/null 2>&1; then
      need_patch=1
    fi
  fi

  if [[ "${need_patch}" -eq 0 ]]; then
    echo "Plist ${PLIST} already contains required SSL args and env vars; skipping patch."
  else
    echo "Patching installed plist ${PLIST} to ensure SSL args and env vars"

    # Add ssl ProgramArguments if missing
    if ! sudo "${PLISTBUDDY}" -c "Print :ProgramArguments" "${PLIST}" 2>/dev/null | grep -q -- "--ssl-certfile"; then
      sudo "${PLISTBUDDY}" -c "Add :ProgramArguments: string --ssl-certfile" "${PLIST}" || true
      sudo "${PLISTBUDDY}" -c "Add :ProgramArguments: string /etc/ssl/certs/server.crt" "${PLIST}" || true
    fi
    if ! sudo "${PLISTBUDDY}" -c "Print :ProgramArguments" "${PLIST}" 2>/dev/null | grep -q -- "--ssl-keyfile"; then
      sudo "${PLISTBUDDY}" -c "Add :ProgramArguments: string --ssl-keyfile" "${PLIST}" || true
      sudo "${PLISTBUDDY}" -c "Add :ProgramArguments: string /etc/ssl/private/server.key" "${PLIST}" || true
    fi

    # Ensure EnvironmentVariables contain canonical paths
    # Use indexed arrays for portability on macOS (bash 3.x doesn't support associative arrays)
    ENV_KEYS=(GATEWAY_TLS_CERT_PATH GATEWAY_TLS_KEY_PATH)
    ENV_VALS=("/etc/ssl/certs/server.crt" "/etc/ssl/private/server.key")
    for i in "${!ENV_KEYS[@]}"; do
      k="${ENV_KEYS[$i]}"
      v="${ENV_VALS[$i]}"
      sudo "${PLISTBUDDY}" -c "Delete :EnvironmentVariables:${k}" "${PLIST}" 2>/dev/null || true
      sudo "${PLISTBUDDY}" -c "Add :EnvironmentVariables:${k} string ${v}" "${PLIST}" || true
    done

    echo "Patched plist EnvironmentVariables:"
    sudo "${PLISTBUDDY}" -c "Print :EnvironmentVariables" "${PLIST}" 2>/dev/null || true
  fi
fi

# kickstart alone is fine if it is already bootstrapped; bootstrap if missing.
if sudo launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
  sudo launchctl kickstart -k "system/${LAUNCHD_LABEL}"
else
  if [[ ! -f "${PLIST}" ]]; then
    echo "ERROR: plist not found at ${PLIST}" >&2
    exit 1
  fi
  sudo launchctl bootstrap system "${PLIST}"
  sudo launchctl kickstart -k "system/${LAUNCHD_LABEL}"
fi

# Ensure redirect job is started if the redirect plist exists
REDIRECT_PLIST="/Library/LaunchDaemons/com.ai.gateway.redirect.plist"
if [[ -f "${REDIRECT_PLIST}" ]]; then
  if sudo launchctl print "system/com.ai.gateway.redirect" >/dev/null 2>&1; then
    sudo launchctl kickstart -k "system/com.ai.gateway.redirect" || true
  else
    sudo launchctl bootstrap system "${REDIRECT_PLIST}" || true
    sudo launchctl kickstart -k "system/com.ai.gateway.redirect" || true
  fi
fi

# ---- verify ----
echo "Waiting for health endpoint..."
for i in {1..30}; do
  # Add explicit timeouts so a stalled connect/read can't hang the deploy.
  if curl -fsS ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC}" --max-time "${CURL_MAX_TIME_SEC}" "${HEALTH_URL}" >/dev/null 2>&1; then
    echo "OK: health endpoint responds"
    break
  fi
  sleep 0.2
  if [[ $i -eq 30 ]]; then
    echo "ERROR: health check failed: ${HEALTH_URL}" >&2
    echo "---- launchctl state ----"
    sudo launchctl print "system/${LAUNCHD_LABEL}" | sed -n '1,200p' || true
    echo "---- recent stderr ----"
    sudo tail -n 200 "${ERR_LOG}" 2>/dev/null || true
    echo "---- recent stdout ----"
    sudo tail -n 200 "${OUT_LOG}" 2>/dev/null || true
    exit 1
  fi
done

echo "Checking port ${PORT}..."
sudo lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN || true

# ---- best-effort: pre-warm / validate music UI ----
# If the static music UI exists in the deployed tree, try to fetch it to warm caches
# and validate basic accessibility. This is best-effort and will not fail the deploy.
if [[ -f "${APP_DIR}/app/static/music.html" ]]; then
  echo "Checking /ui/music..."
  MUSIC_URL="https://127.0.0.1:${PORT}/ui/music"
  UI_OK=0
  for i in {1..6}; do
    if curl -fsS ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC}" --max-time "${CURL_MAX_TIME_SEC}" "${MUSIC_URL}" >/dev/null 2>&1; then
      echo "OK: /ui/music responded"
      UI_OK=1
      break
    else
      status=$(curl -sS ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} -o /dev/null -w "%{http_code}" --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC}" --max-time "${CURL_MAX_TIME_SEC}" "${MUSIC_URL}" || true)
      if [[ "${status}" == "403" ]]; then
        echo "WARN: /ui/music returned 403 (UI may be disabled or your deploy host is not allowlisted)"
        UI_OK=1
        break
      fi
    fi
    sleep 0.2
  done

  if [[ "${UI_OK}" -ne 1 ]]; then
    echo "WARN: /ui/music check failed or timed out (non-200/403 responses); UI may be disabled or misconfigured" >&2
  fi
fi

echo "Deploy complete."

if [[ ${POST_DEPLOY_HOOK} -eq 1 ]]; then
  HOOK_SCRIPT="${SCRIPT_DIR}/post_deploy_hook.sh"
  if [[ -x "${HOOK_SCRIPT}" ]]; then
    echo "Running post-deploy hook (${HOOK_SCRIPT})..."
    "${HOOK_SCRIPT}"
    echo "Post-deploy hook OK."
  else
    echo "ERROR: post-deploy hook enabled but missing/not executable: ${HOOK_SCRIPT}" >&2
    echo "Hint: ensure ai-infra/services/gateway/scripts/post_deploy_hook.sh exists and is executable." >&2
    exit 1
  fi
fi
