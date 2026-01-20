#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: gateway launchd scripts are macOS-only." >&2
  echo "Hint: use services/all/scripts/health-check.sh or verify-stack.sh from any machine." >&2
  exit 1
fi

require_cmd launchctl

LABEL="com.ai.gateway"

echo "== gateway status $(date -u +%Y-%m-%dT%H:%M:%SZ) =="

sudo launchctl print system/"$LABEL" | sed -n '1,220p'

echo "---- deployed commits ----"
if [[ -f /var/lib/gateway/app/DEPLOYED_GATEWAY_COMMIT ]]; then
  echo -n "gateway="
  cat /var/lib/gateway/app/DEPLOYED_GATEWAY_COMMIT
else
  echo "gateway=(missing /var/lib/gateway/app/DEPLOYED_GATEWAY_COMMIT)"
fi

if [[ -f /var/lib/gateway/app/DEPLOYED_AI_INFRA_COMMIT ]]; then
  echo -n "ai-infra="
  cat /var/lib/gateway/app/DEPLOYED_AI_INFRA_COMMIT
else
  echo "ai-infra=(missing /var/lib/gateway/app/DEPLOYED_AI_INFRA_COMMIT)"
fi

echo "---- listener ----"
if sudo lsof -nP -iTCP:8800 -sTCP:LISTEN; then
  PID="$(sudo lsof -t -iTCP:8800 -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  if [[ -n "${PID}" ]]; then
    echo "---- listener command ----"
    sudo ps -p "${PID}" -o pid,user,command -ww || true
  fi
  :
else
  echo "NO LISTENER: nothing bound to TCP/8800" >&2
  echo "Hint: try services/gateway/scripts/restart.sh and re-run verify.sh" >&2
fi

echo "---- recent stderr ----"
sudo tail -n 80 /var/log/gateway/gateway.err.log 2>/dev/null || true

echo "---- recent stdout ----"
sudo tail -n 80 /var/log/gateway/gateway.out.log 2>/dev/null || true

echo "---- post-deploy hook ----"
sudo tail -n 120 /var/log/gateway/post_deploy_hook.log 2>/dev/null || true
