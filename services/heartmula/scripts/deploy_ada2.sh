#!/usr/bin/env bash
set -euo pipefail

# Deploy helper for ada2 (systemd)
ENV_FILE=/etc/heartmula/heartmula.env
SERVICE=com.heartmula.server.service

if [ ! -f "$ENV_FILE" ]; then
  echo "Env file $ENV_FILE not found. Run install_ada2.sh first."
  exit 1
fi

echo "Reloading systemd and restarting $SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"
systemctl status "$SERVICE" --no-pager -l

# Health check
PORT=$(awk -F= '/HEARTMULA_PORT/{print $2}' "$ENV_FILE" | tr -d ' ')
PORT=${PORT:-9920}

for i in 1 2 3 4 5; do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "HeartMula is healthy"
    exit 0
  fi
  sleep 2
done

echo "Health check failed; see journalctl -u com.heartmula.server.service" >&2
exit 2
