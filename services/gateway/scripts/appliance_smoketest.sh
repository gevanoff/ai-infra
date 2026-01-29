#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd uname

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: This script targets macOS (appliance host)." >&2
  exit 1
fi

RUNTIME_ROOT="/var/lib/gateway"
APP_DIR="${RUNTIME_ROOT}/app"
ENV_FILE="${APP_DIR}/.env"
PYTHON_BIN="${RUNTIME_ROOT}/env/bin/python"
SCRIPT_PATH="${APP_DIR}/tools/verify_gateway.py"

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: expected python not found/executable: ${PYTHON_BIN}" >&2
  exit 1
fi

if [[ ! -f "${SCRIPT_PATH}" ]]; then
  echo "ERROR: ${SCRIPT_PATH} not found" >&2
  echo "Hint: run services/gateway/scripts/deploy.sh to deploy the latest gateway tools." >&2
  exit 1
fi

_read_env_file_kv() {
  local key="$1"
  local file="$2"
  [[ -f "${file}" ]] || return 0
  local line
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  line="${line#${key}=}"
  line="${line#\"}"; line="${line%\"}"
  line="${line#\'}"; line="${line%\'}"
  printf '%s' "${line}"
}

BASE_URL="${GATEWAY_BASE_URL:-$(_read_env_file_kv GATEWAY_BASE_URL "${ENV_FILE}")}";
BASE_URL="${BASE_URL:-https://127.0.0.1:8800}"

TOKEN="${GATEWAY_BEARER_TOKEN:-$(_read_env_file_kv GATEWAY_BEARER_TOKEN "${ENV_FILE}")}";
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: GATEWAY_BEARER_TOKEN not set (export it or set it in ${ENV_FILE})." >&2
  exit 1
fi

echo "Running appliance smoketest against ${BASE_URL}"

INSECURE_FLAG=()
if [[ "${GATEWAY_TLS_INSECURE:-}" == "1" || "${GATEWAY_TLS_INSECURE:-}" == "true" ]]; then
  INSECURE_FLAG=("--insecure")
fi

"${PYTHON_BIN}" "${SCRIPT_PATH}" \
  --skip-pytest \
  --base-url "${BASE_URL}" \
  --token "${TOKEN}" \
  ${INSECURE_FLAG[@]+"${INSECURE_FLAG[@]}"} \
  --appliance
