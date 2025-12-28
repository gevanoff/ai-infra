#!/bin/zsh
set -euo pipefail

LABEL="com.ai.gateway"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../launchd/${LABEL}.plist.example"
DST="/Library/LaunchDaemons/${LABEL}.plist"

# Runtime dirs expected by the gateway
sudo mkdir -p /var/lib/gateway/{app,data,tools} /var/log/gateway

if ! id -u gateway >/dev/null 2>&1; then
  echo "ERROR: user 'gateway' does not exist on this machine" >&2
  echo "Hint: create it (or change the plist UserName/chown targets)." >&2
  exit 1
fi

sudo chown -R gateway:staff /var/lib/gateway /var/log/gateway
sudo chmod -R u+rwX,g+rX,o-rwx /var/lib/gateway /var/log/gateway

# Ensure a venv exists (used by the plist)
if [[ ! -x /var/lib/gateway/env/bin/python ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found (needed to create /var/lib/gateway/env venv)" >&2
    exit 1
  fi
  sudo python3 -m venv /var/lib/gateway/env
  sudo /var/lib/gateway/env/bin/python -m pip install -U pip >/dev/null
  sudo chown -R gateway:staff /var/lib/gateway/env
  sudo chmod -R u+rwX,g+rX,o-rwx /var/lib/gateway/env
fi

# Seed .env if missing (do NOT overwrite if it exists)
ENV_EXAMPLE="${HERE}/../env/gateway.env.example"
ENV_DST="/var/lib/gateway/app/.env"
if [[ ! -f "${ENV_DST}" && -f "${ENV_EXAMPLE}" ]]; then
  sudo cp "${ENV_EXAMPLE}" "${ENV_DST}"
  sudo chown gateway:staff "${ENV_DST}"
  sudo chmod 640 "${ENV_DST}"
  echo "NOTE: seeded ${ENV_DST} from gateway.env.example; set GATEWAY_BEARER_TOKEN." >&2
fi

# Install plist
sudo cp "$SRC" "$DST"
sudo chown root:wheel "$DST"
sudo chmod 644 "$DST"

# Validate plist parses as XML property list
sudo plutil -lint "$DST" >/dev/null

# Start now only if the deployed log config exists; otherwise leave installed.
LOGCFG="/var/lib/gateway/app/tools/uvicorn_log_config.json"
if [[ -f "${LOGCFG}" ]]; then
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$DST"
  sudo launchctl kickstart -k system/"$LABEL"
else
  echo "NOTE: ${LOGCFG} not found yet; plist installed but not started." >&2
  echo "Hint: run the gateway deploy script to populate /var/lib/gateway/app, then run scripts/restart.sh" >&2
fi
