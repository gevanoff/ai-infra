#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd curl

BASE_URL="${GATEWAY_BASE_URL:-https://127.0.0.1:8800}"
TOKEN="${GATEWAY_BEARER_TOKEN:-}"
CURL_TLS_ARGS=()
if [[ "${GATEWAY_TLS_INSECURE:-}" == "1" || "${GATEWAY_TLS_INSECURE:-}" == "true" ]]; then
  CURL_TLS_ARGS=(--insecure)
fi

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: GATEWAY_BEARER_TOKEN is not set" >&2
  echo "Usage: GATEWAY_BEARER_TOKEN=... $0" >&2
  echo "Optional: set GATEWAY_BASE_URL (default: ${BASE_URL})" >&2
  exit 1
fi

echo "Base URL: ${BASE_URL}"

echo "[1/4] GET /health"
curl -fsS "${CURL_TLS_ARGS[@]}" "${BASE_URL}/health" >/dev/null

echo "[2/4] GET /v1/models"
curl -fsS "${CURL_TLS_ARGS[@]}" "${BASE_URL}/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" \
  >/dev/null

echo "[3/4] POST /v1/embeddings"
curl -fsS "${CURL_TLS_ARGS[@]}" "${BASE_URL}/v1/embeddings" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"default","input":"smoke test"}' \
  >/dev/null

echo "[4/4] POST /v1/responses (non-stream)"
curl -fsS "${CURL_TLS_ARGS[@]}" "${BASE_URL}/v1/responses" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"fast","input":"smoke test","stream":false}' \
  >/dev/null

echo "OK: smoke tests passed"
