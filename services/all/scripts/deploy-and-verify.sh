#!/bin/bash
# Deploy the stack (all hosts or one host) and then run functional verification.
#
# Usage:
#   ./deploy-and-verify.sh --token <gateway_token>
#   ./deploy-and-verify.sh --check-images --token <gateway_token>
#   ./deploy-and-verify.sh --host ai2 --token <gateway_token>
#
# Notes:
# - Deployment uses deploy-all.sh / deploy-host.sh.
# - Verification uses verify-stack.sh.
# - Gateway checks require an auth token (env GATEWAY_BEARER_TOKEN or --token).

set -euo pipefail

FILTER_HOST=""
CHECK_IMAGES=false
VERBOSE=false
TOKEN="${GATEWAY_BEARER_TOKEN:-}"
TIMEOUT_SEC=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      FILTER_HOST="$2"
      shift 2
      ;;
    --check-images)
      CHECK_IMAGES=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
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

deploy_ok=true
verify_ok=true

echo "=== Deploy ==="
if [[ -n "$FILTER_HOST" ]]; then
  if "$SCRIPT_DIR/deploy-host.sh" "$FILTER_HOST"; then
    echo "✓ deploy-host OK ($FILTER_HOST)"
  else
    echo "✗ deploy-host FAILED ($FILTER_HOST)" >&2
    deploy_ok=false
  fi
else
  if "$SCRIPT_DIR/deploy-all.sh"; then
    echo "✓ deploy-all OK"
  else
    echo "✗ deploy-all FAILED" >&2
    deploy_ok=false
  fi
fi

echo ""
echo "=== Verify ==="
VERIFY_ARGS=()

if [[ -n "$FILTER_HOST" ]]; then
  VERIFY_ARGS+=( --host "$FILTER_HOST" )
fi
if [[ "$CHECK_IMAGES" == "true" ]]; then
  VERIFY_ARGS+=( --check-images )
fi
if [[ "$VERBOSE" == "true" ]]; then
  VERIFY_ARGS+=( --verbose )
fi
if [[ -n "$TOKEN" ]]; then
  VERIFY_ARGS+=( --token "$TOKEN" )
fi
if [[ -n "$TIMEOUT_SEC" ]]; then
  VERIFY_ARGS+=( --timeout "$TIMEOUT_SEC" )
fi

if "$SCRIPT_DIR/verify-stack.sh" "${VERIFY_ARGS[@]}"; then
  echo "✓ verify-stack OK"
else
  echo "✗ verify-stack FAILED" >&2
  verify_ok=false
fi

if [[ "$deploy_ok" == "true" && "$verify_ok" == "true" ]]; then
  exit 0
fi
exit 1
