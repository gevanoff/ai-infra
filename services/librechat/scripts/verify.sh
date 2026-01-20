#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: librechat verify is macOS-only." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 2
  }
}

require_cmd sudo
require_cmd curl
require_cmd lsof

ENV_FILE="/var/lib/librechat/app/.env"
YAML_FILE="/var/lib/librechat/app/librechat.yaml"

PORT="${LIBRECHAT_PORT:-3080}"

SUDO="sudo"
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
fi

fail() {
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "OK: $*"
}

echo "Checking MongoDB listener..."
${SUDO} lsof -nP -iTCP:27017 -sTCP:LISTEN >/dev/null || fail "MongoDB is not listening on TCP/27017. Try: sudo services/librechat/scripts/restart.sh ; then services/librechat/scripts/status.sh"
pass "MongoDB is listening on TCP/27017"

echo "Checking LibreChat /health..."
curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q "OK" || fail "LibreChat /health did not return OK on http://127.0.0.1:${PORT}/health"
pass "LibreChat /health is OK"

echo "Checking LibreChat env (gateway-only)..."
${SUDO} /bin/test -f "$ENV_FILE" || fail "Missing env file: $ENV_FILE"
${SUDO} grep -q '^ENDPOINTS=custom$' "$ENV_FILE" || fail "Expected ENDPOINTS=custom in $ENV_FILE"
pass "ENDPOINTS=custom"

echo "Checking gateway token configured..."
${SUDO} grep -q '^GATEWAY_BEARER_TOKEN=.' "$ENV_FILE" || fail "Missing/empty GATEWAY_BEARER_TOKEN in $ENV_FILE (LibreChat won't be able to call the gateway, and the model list may be empty)"
pass "GATEWAY_BEARER_TOKEN is set"

echo "Checking gateway listener (TCP/8800)..."
${SUDO} lsof -nP -iTCP:8800 -sTCP:LISTEN >/dev/null || fail "Gateway is not listening on TCP/8800. LibreChat will time out calling the custom endpoint."
pass "Gateway is listening on TCP/8800"

echo "Checking LibreChat YAML hardening (Actions/MCP disabled)..."
${SUDO} /bin/test -f "$YAML_FILE" || fail "Missing YAML config: $YAML_FILE"

echo "Checking LibreChat YAML custom endpoint + default model..."
${SUDO} grep -q "^endpoints:$" "$YAML_FILE" || fail "Missing 'endpoints:' in $YAML_FILE"
${SUDO} grep -q "^  custom:$" "$YAML_FILE" || fail "Missing 'endpoints.custom' in $YAML_FILE"
${SUDO} grep -E -q "^      baseURL: 'https?://[^']+:8800/v1'$" "$YAML_FILE" || fail "Expected a gateway baseURL like 'http://127.0.0.1:8800/v1' in $YAML_FILE"
${SUDO} grep -q "^        default: \['auto'\]$" "$YAML_FILE" || fail "Expected models.default ['auto'] in $YAML_FILE"
pass "Custom endpoint + default model present"

# These checks are intentionally simple string matches.
# The provided ai-infra harden/template scripts write these blocks deterministically.
${SUDO} grep -q '^actions:$' "$YAML_FILE" || fail "Missing 'actions:' block in $YAML_FILE"
${SUDO} grep -q '^  allowedDomains: \[\]$' "$YAML_FILE" || fail "Expected 'actions.allowedDomains: []' in $YAML_FILE"

${SUDO} grep -q '^mcpSettings:$' "$YAML_FILE" || fail "Missing 'mcpSettings:' block in $YAML_FILE"
${SUDO} grep -q '^  allowedDomains: \[\]$' "$YAML_FILE" || fail "Expected 'mcpSettings.allowedDomains: []' in $YAML_FILE"

${SUDO} grep -q '^interface:$' "$YAML_FILE" || fail "Missing 'interface:' block in $YAML_FILE"
${SUDO} grep -q '^  mcpServers:$' "$YAML_FILE" || fail "Missing 'interface.mcpServers' block in $YAML_FILE"
${SUDO} grep -q '^    use: false$' "$YAML_FILE" || fail "Expected 'interface.mcpServers.use: false' in $YAML_FILE"
${SUDO} grep -q '^    create: false$' "$YAML_FILE" || fail "Expected 'interface.mcpServers.create: false' in $YAML_FILE"
pass "Actions + MCP hardening present"

echo "OK"
