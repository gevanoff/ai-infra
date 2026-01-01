#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd uname

BASE_URL="${GATEWAY_BASE_URL:-http://127.0.0.1:8800}"
TOKEN="${GATEWAY_BEARER_TOKEN:-}"

REQUIRE_BACKEND=0
RUN_PYTEST=0

usage() {
  cat <<EOF
Usage: GATEWAY_BEARER_TOKEN=... $0 [--require-backend] [--pytest]

Runs the gateway comprehensive verifier against an already-running gateway.

Env:
  GATEWAY_BEARER_TOKEN   (required)
  GATEWAY_BASE_URL       default: ${BASE_URL}

Flags:
  --require-backend   Fail if no healthy upstreams (Ollama/MLX) are reported.
  --pytest            Also run pytest in the deployed app dir (requires pytest installed in /var/lib/gateway/env).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-backend)
      REQUIRE_BACKEND=1
      shift
      ;;
    --pytest)
      RUN_PYTEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: GATEWAY_BEARER_TOKEN is not set" >&2
  usage >&2
  exit 1
fi

PYTHON_BIN=""
if [[ -x "/var/lib/gateway/env/bin/python" ]]; then
  PYTHON_BIN="/var/lib/gateway/env/bin/python"
else
  require_cmd python3
  PYTHON_BIN="python3"
fi

SCRIPT_PATH=""
if [[ -f "/var/lib/gateway/app/tools/verify_gateway.py" ]]; then
  SCRIPT_PATH="/var/lib/gateway/app/tools/verify_gateway.py"
else
  # Fallback: run from a gateway repo checkout if present next to ai-infra.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SERVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"          # ai-infra/services/gateway
  AI_INFRA_ROOT="$(cd "${SERVICE_DIR}/../.." && pwd)"     # ai-infra

  SRC_DIR=""
  for cand in \
    "${GATEWAY_SRC_DIR:-}" \
    "${AI_INFRA_ROOT}/../gateway" \
    "${AI_INFRA_ROOT}/../../gateway" \
  ; do
    [[ -n "${cand}" ]] || continue
    if [[ -f "${cand}/tools/verify_gateway.py" ]]; then
      SRC_DIR="${cand}"
      break
    fi
  done

  if [[ -n "${SRC_DIR}" ]]; then
    SCRIPT_PATH="${SRC_DIR}/tools/verify_gateway.py"
  fi
fi

if [[ -z "${SCRIPT_PATH}" ]]; then
  echo "ERROR: could not find verify_gateway.py." >&2
  echo "Expected: /var/lib/gateway/app/tools/verify_gateway.py" >&2
  echo "Hint: run services/gateway/scripts/deploy.sh to deploy the latest gateway tools." >&2
  exit 1
fi

declare -a EXTRA_ARGS=()
if [[ ${REQUIRE_BACKEND} -eq 1 ]]; then
  EXTRA_ARGS+=("--require-backend")
fi

echo "Base URL: ${BASE_URL}"

"${PYTHON_BIN}" "${SCRIPT_PATH}" --skip-pytest --base-url "${BASE_URL}" --token "${TOKEN}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

if [[ ${RUN_PYTEST} -eq 1 ]]; then
  if [[ ! -d "/var/lib/gateway/app" ]]; then
    echo "ERROR: /var/lib/gateway/app not found; cannot run pytest" >&2
    exit 1
  fi
  if command -v sudo >/dev/null 2>&1; then
    echo "Running pytest in /var/lib/gateway/app (as user 'gateway') ..."
    (cd "/var/lib/gateway/app" && sudo -u gateway -H env MEMORY_ENABLED=false MEMORY_V2_ENABLED=false "${PYTHON_BIN}" -m pytest -q)
  else
    echo "ERROR: sudo is required for --pytest (to run tests as user 'gateway')." >&2
    exit 1
  fi
fi
