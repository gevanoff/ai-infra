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

fail() {
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "OK: $*"
}

echo "Checking MongoDB listener..."
sudo lsof -nP -iTCP:27017 -sTCP:LISTEN >/dev/null || fail "MongoDB is not listening on TCP/27017. Try: sudo services/librechat/scripts/restart.sh ; then services/librechat/scripts/status.sh"
pass "MongoDB is listening on TCP/27017"

echo "Checking LibreChat /health..."
curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q "OK" || fail "LibreChat /health did not return OK on http://127.0.0.1:${PORT}/health"
pass "LibreChat /health is OK"

echo "Checking LibreChat env (gateway-only)..."
test -f "$ENV_FILE" || fail "Missing env file: $ENV_FILE"
grep -q '^ENDPOINTS=custom$' "$ENV_FILE" || fail "Expected ENDPOINTS=custom in $ENV_FILE"
pass "ENDPOINTS=custom"

echo "Checking LibreChat YAML hardening (Actions/MCP disabled)..."
test -f "$YAML_FILE" || fail "Missing YAML config: $YAML_FILE"

# These checks are intentionally simple string matches.
# The provided ai-infra harden/template scripts write these blocks deterministically.
grep -q '^actions:$' "$YAML_FILE" || fail "Missing 'actions:' block in $YAML_FILE"
grep -q '^  allowedDomains: \[\]$' "$YAML_FILE" || fail "Expected 'actions.allowedDomains: []' in $YAML_FILE"

grep -q '^mcpSettings:$' "$YAML_FILE" || fail "Missing 'mcpSettings:' block in $YAML_FILE"
grep -q '^  allowedDomains: \[\]$' "$YAML_FILE" || fail "Expected 'mcpSettings.allowedDomains: []' in $YAML_FILE"

grep -q '^interface:$' "$YAML_FILE" || fail "Missing 'interface:' block in $YAML_FILE"
grep -q '^  mcpServers:$' "$YAML_FILE" || fail "Missing 'interface.mcpServers' block in $YAML_FILE"
grep -q '^    use: false$' "$YAML_FILE" || fail "Expected 'interface.mcpServers.use: false' in $YAML_FILE"
grep -q '^    create: false$' "$YAML_FILE" || fail "Expected 'interface.mcpServers.create: false' in $YAML_FILE"
pass "Actions + MCP hardening present"

echo "OK"
