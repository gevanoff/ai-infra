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
SCRIPT_PATH="${APP_DIR}/tools/freeze_release.py"

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
  # Grab the last assignment, strip leading KEY=, strip surrounding quotes.
  local line
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  line="${line#${key}=}"
  # Strip surrounding single/double quotes.
  line="${line#\"}"; line="${line%\"}"
  line="${line#\'}"; line="${line%\'}"
  printf '%s' "${line}"
}

BASE_URL="${GATEWAY_BASE_URL:-$(_read_env_file_kv GATEWAY_BASE_URL "${ENV_FILE}")}";
BASE_URL="${BASE_URL:-http://127.0.0.1:8800}"

TOKEN="${GATEWAY_BEARER_TOKEN:-$(_read_env_file_kv GATEWAY_BEARER_TOKEN "${ENV_FILE}")}";
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: GATEWAY_BEARER_TOKEN not set (export it or set it in ${ENV_FILE})." >&2
  exit 1
fi

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-$(_read_env_file_kv OLLAMA_BASE_URL "${ENV_FILE}")}";
MLX_BASE_URL="${MLX_BASE_URL:-$(_read_env_file_kv MLX_BASE_URL "${ENV_FILE}")}";

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${RUNTIME_ROOT}/data/releases/${STAMP}"
OUT_PATH="${OUT_DIR}/release_manifest.json"
LATEST_PATH="${RUNTIME_ROOT}/data/releases/latest.json"

sudo mkdir -p "${OUT_DIR}"
sudo chown -R gateway:staff "${RUNTIME_ROOT}/data/releases" || true

echo "Freezing release manifest to ${OUT_PATH}"

"${PYTHON_BIN}" "${SCRIPT_PATH}" \
  --base-url "${BASE_URL}" \
  --token "${TOKEN}" \
  --ollama-base-url "${OLLAMA_BASE_URL}" \
  --mlx-base-url "${MLX_BASE_URL}" \
  --out "${OUT_PATH}"

sudo ln -sf "${OUT_PATH}" "${LATEST_PATH}" || true

echo "OK: wrote ${OUT_PATH}"
