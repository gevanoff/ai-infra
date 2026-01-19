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

require_cmd curl
require_cmd lsof

ENV_FILE="/var/lib/librechat/app/.env"
YAML_FILE="/var/lib/librechat/app/librechat.yaml"

PORT="${LIBRECHAT_PORT:-3080}"

echo "Checking MongoDB listener..."
lsof -nP -iTCP:27017 -sTCP:LISTEN >/dev/null

echo "Checking LibreChat /health..."
curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q "OK"

echo "Checking LibreChat env (gateway-only)..."
test -f "$ENV_FILE"
grep -q '^ENDPOINTS=custom$' "$ENV_FILE"

echo "Checking LibreChat YAML hardening (Actions/MCP disabled)..."
test -f "$YAML_FILE"

# These checks are intentionally simple string matches.
# The provided ai-infra harden/template scripts write these blocks deterministically.
grep -q '^actions:$' "$YAML_FILE"
grep -q '^  allowedDomains: \[\]$' "$YAML_FILE"

grep -q '^mcpSettings:$' "$YAML_FILE"
grep -q '^  allowedDomains: \[\]$' "$YAML_FILE"

grep -q '^interface:$' "$YAML_FILE"
grep -q '^  mcpServers:$' "$YAML_FILE"
grep -q '^    use: false$' "$YAML_FILE"
grep -q '^    create: false$' "$YAML_FILE"

echo "OK"
