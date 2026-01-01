#!/bin/zsh
set -euo pipefail

LABEL="com.ai.gateway"

sudo launchctl print system/"$LABEL" | sed -n '1,220p'

echo "---- listener ----"
sudo lsof -nP -iTCP:8800 -sTCP:LISTEN || true

echo "---- recent stderr ----"
sudo tail -n 80 /var/log/gateway/gateway.err.log 2>/dev/null || true

echo "---- recent stdout ----"
sudo tail -n 80 /var/log/gateway/gateway.out.log 2>/dev/null || true

echo "---- post-deploy hook ----"
sudo tail -n 120 /var/log/gateway/post_deploy_hook.log 2>/dev/null || true
