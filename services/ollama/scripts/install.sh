#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

note() {
  echo "$*" >&2
}

ensure_firewall_allow_tcp_port_from_cidr() {
  local cidr="$1"
  local port="$2"

  # Prefer UFW when it's active.
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status="$(sudo ufw status 2>/dev/null || true)"
    if echo "$ufw_status" | grep -qiE '^Status:\s+active'; then
      note "Configuring firewall via ufw: allow tcp/${port} from ${cidr}"
      if sudo ufw allow from "$cidr" to any port "$port" proto tcp comment "ollama" >/dev/null 2>&1; then
        return 0
      fi
      sudo ufw allow from "$cidr" to any port "$port" proto tcp >/dev/null
      return 0
    fi
  fi

  # Next best: firewalld, if it's running.
  if command -v firewall-cmd >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
      local rule
      rule="rule family=ipv4 source address=${cidr} port protocol=tcp port=${port} accept"
      note "Configuring firewall via firewalld rich rule: allow tcp/${port} from ${cidr}"
      if sudo firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
        note "Firewall already allows tcp/${port} from ${cidr} (firewalld)"
      else
        sudo firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
        sudo firewall-cmd --reload >/dev/null
      fi
      return 0
    fi
  fi

  # Fallback: direct iptables rule (may not be persistent).
  if command -v iptables >/dev/null 2>&1; then
    note "Configuring firewall via iptables: allow tcp/${port} from ${cidr}"
    if sudo iptables -C INPUT -p tcp -s "$cidr" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      note "Firewall already allows tcp/${port} from ${cidr} (iptables)"
      return 0
    fi
    sudo iptables -I INPUT 1 -p tcp -s "$cidr" --dport "$port" -j ACCEPT
    if command -v netfilter-persistent >/dev/null 2>&1; then
      sudo netfilter-persistent save >/dev/null 2>&1 || true
    fi
    note "NOTE: iptables rule may not persist across reboot unless saved (e.g. netfilter-persistent/iptables-persistent)."
    return 0
  fi

  note "NOTE: No supported firewall manager found (ufw/firewalld/iptables). Ensure tcp/${port} is allowed from ${cidr}."
}

OS="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$OS" == "Darwin" ]]; then
  require_cmd launchctl
  require_cmd plutil

  LABEL="com.ollama.server"
  HERE="$(cd "$(dirname "$0")" && pwd)"
  SRC="${HERE}/../launchd/${LABEL}.plist.example"
  DST="/Library/LaunchDaemons/${LABEL}.plist"
  OLLAMA_USER="${OLLAMA_USER:-ollama}"

  # Runtime dirs (only if your plist/env uses them)
  sudo mkdir -p /var/lib/ollama/{run,cache} /var/log/ollama

  if ! id -u "${OLLAMA_USER}" >/dev/null 2>&1; then
    echo "ERROR: user '${OLLAMA_USER}' does not exist on this machine" >&2
    echo "Hint: create it (or set OLLAMA_USER / update the plist UserName and chown targets)." >&2
    exit 1
  fi

  sudo chown -R "${OLLAMA_USER}":staff /var/lib/ollama /var/log/ollama
  sudo chmod 750 /var/lib/ollama /var/log/ollama

  # Install plist
  sudo cp "$SRC" "$DST"
  sudo chown root:wheel "$DST"
  sudo chmod 644 "$DST"
  sudo plutil -lint "$DST" >/dev/null

  # Reload service
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$DST"
  sudo launchctl kickstart -k system/"$LABEL"
  exit 0
fi

if [[ "$OS" == "Linux" ]]; then
  # Prefer systemd if present.
  if command -v systemctl >/dev/null 2>&1; then
    if ! command -v ollama >/dev/null 2>&1; then
      echo "ERROR: ollama binary not found in PATH." >&2
      echo "Hint: install Ollama (Ubuntu) then re-run this script." >&2
      echo "  - https://ollama.com/download" >&2
      exit 1
    fi

    OLLAMA_FIREWALL_CIDR="${OLLAMA_FIREWALL_CIDR:-10.10.22.0/24}"
    OLLAMA_FIREWALL_PORT="${OLLAMA_FIREWALL_PORT:-11434}"
    OLLAMA_SKIP_FIREWALL="${OLLAMA_SKIP_FIREWALL:-0}"

    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable --now ollama >/dev/null 2>&1 || sudo systemctl restart ollama

    if [[ "$OLLAMA_SKIP_FIREWALL" != "1" ]]; then
      ensure_firewall_allow_tcp_port_from_cidr "$OLLAMA_FIREWALL_CIDR" "$OLLAMA_FIREWALL_PORT"
    else
      note "Skipping firewall configuration (OLLAMA_SKIP_FIREWALL=1)"
    fi

    if command -v ss >/dev/null 2>&1; then
      if ss -ltnH "sport = :${OLLAMA_FIREWALL_PORT}" 2>/dev/null | grep -qE '(127\.0\.0\.1|\[::1\]):'"${OLLAMA_FIREWALL_PORT}"; then
        note "NOTE: ollama appears bound to loopback for tcp/${OLLAMA_FIREWALL_PORT}; LAN clients will not reach it even with firewall open."
        note "      Set OLLAMA_HOST=0.0.0.0:${OLLAMA_FIREWALL_PORT} in the ollama systemd environment and restart if LAN access is intended."
      fi
    fi

    echo "✓ ollama service enabled/started (systemd)" >&2
    exit 0
  fi

  echo "ERROR: systemctl not found; cannot manage ollama as a service on Linux." >&2
  echo "Hint: install/enable systemd unit or run ollama manually." >&2
  exit 1
fi

echo "ERROR: unsupported OS for this script: $OS" >&2
exit 1
