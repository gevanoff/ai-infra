#!/bin/bash
# Verify the functional health of the AI stack across hosts.
#
# This is a stronger check than health-check.sh:
# - Gateway: /health + /v1/models + /v1/chat/completions (+ optional /v1/images/generations)
# - MLX: /v1/models
# - Ollama: /api/tags
# - InvokeAI/nginx: /healthz (+ best-effort /readyz)
#
# Usage:
#   ./verify-stack.sh
#   ./verify-stack.sh --token <gateway_token>
#   ./verify-stack.sh --check-images --token <gateway_token>
#   ./verify-stack.sh --host ai2
#
# Environment:
#   GATEWAY_BEARER_TOKEN can be used instead of --token.

set -euo pipefail

VERBOSE=false
FILTER_HOST=""
CHECK_IMAGES=false
TOKEN="${GATEWAY_BEARER_TOKEN:-}"
TIMEOUT_SEC=20

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --host)
      FILTER_HOST="$2"
      shift 2
      ;;
    --check-images)
      CHECK_IMAGES=true
      shift
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOSTS_FILE="$REPO_ROOT/hosts.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Error: hosts.yaml not found at $HOSTS_FILE" >&2
  exit 1
fi

# yq is used for hosts.yaml parsing
if ! command -v yq &> /dev/null; then
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Installing yq..." >&2
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
  else
    echo "Error: yq is required but not installed." >&2
    echo "Install with: brew install yq (macOS)" >&2
    exit 1
  fi
fi

require_cmd curl
require_cmd python3

mktemp_file() {
  if command -v mktemp >/dev/null 2>&1; then
    mktemp
  else
    # extremely minimal fallback
    echo "/tmp/verify-stack.$RANDOM.$RANDOM"
  fi
}

http_json() {
  # args: METHOD URL OUT_BODY [HEADER...]
  local method="$1"
  local url="$2"
  local out_body="$3"
  shift 3

  local hdr_args=()
  while [[ $# -gt 0 ]]; do
    hdr_args+=( -H "$1" )
    shift
  done

  curl -sS -o "$out_body" -w "%{http_code}" --max-time "$TIMEOUT_SEC" -X "$method" "${hdr_args[@]}" "$url"
}

pass() {
  echo "✓ $1"
}

fail() {
  echo "✗ $1" >&2
}

note() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "  $1" >&2
  fi
}

check_simple_get_200() {
  local name="$1"
  local url="$2"
  shift 2

  local body
  body="$(mktemp_file)"

  local code
  code=$(http_json "GET" "$url" "$body" "$@" || true)

  if [[ "$code" == "200" ]]; then
    pass "$name"
    rm -f "$body" || true
    return 0
  fi

  fail "$name (status=$code)"
  if [[ "$VERBOSE" == "true" ]]; then
    note "URL: $url"
    sed 's/^/  body: /' "$body" 2>/dev/null | head -n 5 >&2 || true
  fi
  rm -f "$body" || true
  return 1
}

check_gateway() {
  local host="$1"
  local hostname="$2"
  local port="$3"

  local base="http://${hostname}:${port}"
  echo "  gateway:"

  if [[ -z "$TOKEN" ]]; then
    fail "gateway token missing (set GATEWAY_BEARER_TOKEN or pass --token)"
    return 1
  fi

  local auth="Authorization: Bearer ${TOKEN}"

  local ok_count=0
  local bad_count=0

  if check_simple_get_200 "health" "${base}/health" "$auth"; then ok_count=$((ok_count+1)); else bad_count=$((bad_count+1)); fi
  if check_simple_get_200 "models" "${base}/v1/models" "$auth"; then ok_count=$((ok_count+1)); else bad_count=$((bad_count+1)); fi

  # Chat completion
  local body
  body="$(mktemp_file)"
  local payload
  payload='{"model":"fast","messages":[{"role":"user","content":"verify-stack ping"}],"max_tokens":8}'

  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" --max-time "$((TIMEOUT_SEC * 2))" \
    -X POST "${base}/v1/chat/completions" \
    -H "$auth" -H "Content-Type: application/json" \
    --data "$payload" || true)

  if [[ "$code" == "200" ]]; then
    pass "chat_completions"
    ok_count=$((ok_count+1))
  else
    fail "chat_completions (status=$code)"
    bad_count=$((bad_count+1))
    if [[ "$VERBOSE" == "true" ]]; then
      note "URL: ${base}/v1/chat/completions"
      sed 's/^/  body: /' "$body" 2>/dev/null | head -n 8 >&2 || true
    fi
  fi
  rm -f "$body" || true

  if [[ "$CHECK_IMAGES" == "true" ]]; then
    local body_url body_b64
    body_url="$(mktemp_file)"
    body_b64="$(mktemp_file)"

    local payload_url payload_b64
    payload_url='{"prompt":"verify-stack images url","size":"256x256","n":1}'
    payload_b64='{"prompt":"verify-stack images b64","size":"256x256","n":1,"response_format":"b64_json"}'

    local code_url code_b64
    code_url=$(curl -sS -o "$body_url" -w "%{http_code}" --max-time 180 \
      -X POST "${base}/v1/images/generations" \
      -H "$auth" -H "Content-Type: application/json" \
      --data "$payload_url" || true)

    if [[ "$code_url" != "200" ]]; then
      fail "images_url (status=$code_url)"
      bad_count=$((bad_count+1))
      if [[ "$VERBOSE" == "true" ]]; then
        note "URL: ${base}/v1/images/generations"
        sed 's/^/  body: /' "$body_url" 2>/dev/null | head -n 8 >&2 || true
      fi
    else
      if python3 - "$body_url" <<'PY'
import json,sys
p=sys.argv[1]
with open(p,'rb') as f:
    out=json.load(f)
if not isinstance(out, dict):
    raise SystemExit(2)
data=out.get('data')
if not (isinstance(data, list) and data and isinstance(data[0], dict)):
    raise SystemExit(3)
if 'url' not in data[0]:
    raise SystemExit(4)
if 'b64_json' in data[0]:
    raise SystemExit(5)
PY
      then
        pass "images_url"
        ok_count=$((ok_count+1))
      else
        fail "images_url (invalid response)"
        bad_count=$((bad_count+1))
      fi
    fi

    code_b64=$(curl -sS -o "$body_b64" -w "%{http_code}" --max-time 180 \
      -X POST "${base}/v1/images/generations" \
      -H "$auth" -H "Content-Type: application/json" \
      --data "$payload_b64" || true)

    if [[ "$code_b64" != "200" ]]; then
      fail "images_b64 (status=$code_b64)"
      bad_count=$((bad_count+1))
      if [[ "$VERBOSE" == "true" ]]; then
        note "URL: ${base}/v1/images/generations"
        sed 's/^/  body: /' "$body_b64" 2>/dev/null | head -n 8 >&2 || true
      fi
    else
      if python3 - "$body_b64" <<'PY'
import base64,json,sys
p=sys.argv[1]
with open(p,'rb') as f:
    out=json.load(f)
if not isinstance(out, dict):
    raise SystemExit(2)
data=out.get('data')
if not (isinstance(data, list) and data and isinstance(data[0], dict) and isinstance(data[0].get('b64_json'), str)):
    raise SystemExit(3)
raw=base64.b64decode(data[0]['b64_json'].encode('ascii'))
# Accept PNG; allow SVG placeholders too.
if raw.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit(0)
head=raw[:200].lstrip()
if head.startswith(b"<svg") or head.startswith(b"<?xml"):
    raise SystemExit(0)
raise SystemExit(4)
PY
      then
        pass "images_b64"
        ok_count=$((ok_count+1))
      else
        fail "images_b64 (invalid response)"
        bad_count=$((bad_count+1))
      fi
    fi

    rm -f "$body_url" "$body_b64" || true
  fi

  if [[ $bad_count -eq 0 ]]; then
    return 0
  fi
  return 1
}

check_mlx() {
  local hostname="$1"
  local port="$2"
  local healthz="$3"

  echo "  mlx:"
  check_simple_get_200 "models" "http://${hostname}:${port}${healthz}"
}

check_ollama() {
  local hostname="$1"
  local port="$2"
  local healthz="$3"

  echo "  ollama:"
  check_simple_get_200 "tags" "http://${hostname}:${port}${healthz}"
}

check_invokeai() {
  local hostname="$1"
  local port="$2"
  local healthz="$3"

  echo "  invokeai:"
  local ok=true

  if ! check_simple_get_200 "healthz" "http://${hostname}:${port}${healthz}"; then
    ok=false
  fi

  # best-effort; nginx fronting InvokeAI/shim usually exposes /readyz
  local readyz_url="http://${hostname}:${port}/readyz"
  local body
  body="$(mktemp_file)"
  local code
  code=$(http_json "GET" "$readyz_url" "$body" || true)

  if [[ "$code" == "200" ]]; then
    pass "readyz"
  else
    if [[ "$VERBOSE" == "true" ]]; then
      note "readyz not 200 (status=$code) at $readyz_url"
    fi
  fi
  rm -f "$body" || true

  if [[ "$ok" == "true" ]]; then
    return 0
  fi
  return 1
}

# Determine hosts to verify
if [[ -n "$FILTER_HOST" ]]; then
  HOSTS="$FILTER_HOST"
else
  HOSTS=$(yq '.hosts | keys | .[]' "$HOSTS_FILE")
fi

echo "=== AI Infrastructure Verify Stack ==="
echo ""

TOTAL=0
FAILED=0

for host in $HOSTS; do
  hostname=$(yq ".hosts.$host.hostname" "$HOSTS_FILE")
  if [[ "$hostname" == "null" ]]; then
    echo "Error: Host '$host' not found in hosts.yaml" >&2
    continue
  fi

  echo "$host ($hostname):"

  roles=$(yq ".hosts.$host.roles[]" "$HOSTS_FILE")
  host_failed=false

  for role in $roles; do
    port=$(yq ".services.$role.port" "$HOSTS_FILE")
    healthz=$(yq ".services.$role.healthz" "$HOSTS_FILE")

    if [[ "$port" == "null" ]]; then
      echo "  Warning: Service '$role' not defined in hosts.yaml services section" >&2
      continue
    fi

    TOTAL=$((TOTAL + 1))

    case "$role" in
      gateway)
        if ! check_gateway "$host" "$hostname" "$port"; then
          host_failed=true
        fi
        ;;
      mlx)
        if ! check_mlx "$hostname" "$port" "$healthz"; then
          host_failed=true
        fi
        ;;
      ollama)
        if ! check_ollama "$hostname" "$port" "$healthz"; then
          host_failed=true
        fi
        ;;
      invokeai)
        if ! check_invokeai "$hostname" "$port" "$healthz"; then
          host_failed=true
        fi
        ;;
      *)
        echo "  Warning: Unknown role '$role'" >&2
        ;;
    esac
  done

  if [[ "$host_failed" == "true" ]]; then
    FAILED=$((FAILED + 1))
  fi

  echo ""
done

echo "========================================"
echo "Summary: $((TOTAL - FAILED))/$TOTAL host-role groups OK"

if [[ $FAILED -eq 0 ]]; then
  echo "✓ Stack verification OK"
  exit 0
else
  echo "✗ $FAILED host(s) had failures" >&2
  exit 1
fi
