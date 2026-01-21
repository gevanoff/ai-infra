#!/usr/bin/env bash
set -euo pipefail

# Deploy helper for HeartMula service (macOS)
# - Copies server script to /var/lib/heartmula
# - Installs plist to /Library/LaunchDaemons
# - Ensures ownership/permissions
# - Restarts the launchd job and checks health

LABEL="com.heartmula.server"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_SERVER="${HERE}/../heartmula_server.py"
DST_SERVER="/var/lib/heartmula/heartmula_server.py"
PLIST_SRC="${HERE}/../launchd/${LABEL}.plist.example"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"

echo "HeartMula: copying server script to ${DST_SERVER}..."
sudo mkdir -p /var/lib/heartmula
sudo cp "$SRC_SERVER" "$DST_SERVER"
sudo chown heartmula:staff "$DST_SERVER" || sudo chown root:wheel "$DST_SERVER"
sudo chmod 755 "$DST_SERVER"

echo "HeartMula: installing plist to ${PLIST_DST}..."
sudo cp "$PLIST_SRC" "$PLIST_DST"
sudo chown root:wheel "$PLIST_DST"
sudo chmod 644 "$PLIST_DST"

echo "HeartMula: validating plist"
sudo plutil -lint "$PLIST_DST"

# Try to unload existing job (ignore errors)
sudo launchctl bootout system/${LABEL} 2>/dev/null || true
sudo launchctl bootout system "$PLIST_DST" 2>/dev/null || true

echo "HeartMula: loading plist into launchd"
sudo launchctl bootstrap system "$PLIST_DST"

echo "HeartMula: kickstarting service"
sudo launchctl kickstart -k system/${LABEL}

echo "Waiting a few seconds for service to start..."
sleep 3

echo "Checking health endpoint..."
if curl -sS http://127.0.0.1:9920/health | grep -q "healthy"; then
  echo "HeartMula service is healthy"
  exit 0
else
  echo "HeartMula health check failed; dumping recent logs:" >&2
  sudo tail -n 200 /var/log/heartmula/heartmula.err.log || true
  sudo tail -n 200 /var/log/heartmula/heartmula.out.log || true
  exit 1
fi
