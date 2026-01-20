#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
  echo "ERROR: FollowYourCanvas install script is Linux-only (systemd)." >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this installer must run as root (sudo not found)." >&2
    exit 1
  fi
  # Re-exec as root and preserve environment variables (notably FYC_REPO_URL).
  exec sudo -E bash "$0" "$@"
fi

require_cmd systemctl
require_cmd git
require_cmd python3
require_cmd id

LABEL="followyourcanvas"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICE_SRC="${HERE}/../systemd/${LABEL}.service"
SERVICE_DST="/etc/systemd/system/${LABEL}.service"
ENV_EXAMPLE="${HERE}/../env/followyourcanvas.env.example"
ENV_DST="/var/lib/followyourcanvas/followyourcanvas.env"
APP_DIR="/var/lib/followyourcanvas/app"
VENV_DIR="/var/lib/followyourcanvas/venv"
RUNTIME_DIR="/var/lib/followyourcanvas"
LOG_DIR="/var/log/followyourcanvas"
FYC_USER="${FYC_USER:-followyourcanvas}"

ensure_service_user() {
  local user="$1"
  local home="$2"

  if id -u "$user" >/dev/null 2>&1; then
    return 0
  fi

  require_cmd useradd
  require_cmd groupadd
  require_cmd getent

  if ! getent group "$user" >/dev/null 2>&1; then
    groupadd --system "$user"
  fi

  local nologin_shell="/usr/sbin/nologin"
  if [[ ! -x "$nologin_shell" ]]; then
    nologin_shell="/sbin/nologin"
  fi

  useradd --system \
    --gid "$user" \
    --home-dir "$home" \
    --create-home \
    --shell "$nologin_shell" \
    "$user"
}

# Create the service user early so all subsequent mkdir/chown operations have
# correct ownership from the start.
ensure_service_user "$FYC_USER" "$RUNTIME_DIR"

# Ensure the env file exists early so users can configure the service via
# /var/lib/followyourcanvas/followyourcanvas.env (sudo does not always preserve env vars).
if [[ ! -f "${ENV_DST}" ]]; then
  mkdir -p "$(dirname "${ENV_DST}")"
  cp "${ENV_EXAMPLE}" "${ENV_DST}"
  chown "${FYC_USER}":"${FYC_USER}" "${ENV_DST}"
  chmod 640 "${ENV_DST}" || true
fi

if [[ -f "${ENV_DST}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_DST}"
  set +a
fi

if [[ -z "${FYC_REPO_URL:-}" ]]; then
  echo "ERROR: FYC_REPO_URL is required." >&2
  echo "Set it either in ${ENV_DST} (recommended) or via env when invoking the script." >&2
  echo "Examples:" >&2
  echo "  sudo -E FYC_REPO_URL=https://github.com/mayuelala/FollowYourCanvas.git ${HERE}/install.sh" >&2
  echo "  FYC_REPO_URL=https://github.com/mayuelala/FollowYourCanvas.git ${HERE}/install.sh" >&2
  exit 1
fi

mkdir -p "${RUNTIME_DIR}" "${LOG_DIR}"
chown -R "${FYC_USER}":"${FYC_USER}" "${RUNTIME_DIR}" "${LOG_DIR}"
chmod 750 "${RUNTIME_DIR}" "${LOG_DIR}"

if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "Cloning FollowYourCanvas repo..." >&2
  sudo -u "${FYC_USER}" git clone "${FYC_REPO_URL}" "${APP_DIR}"
fi

if [[ -n "${FYC_REPO_REF:-}" ]]; then
  echo "Checking out ${FYC_REPO_REF}..." >&2
  sudo -u "${FYC_USER}" git -C "${APP_DIR}" fetch --all --tags
  sudo -u "${FYC_USER}" git -C "${APP_DIR}" checkout "${FYC_REPO_REF}"
fi

if [[ ! -d "${VENV_DIR}" ]]; then
  echo "Creating venv..." >&2
  sudo -u "${FYC_USER}" python3 -m venv "${VENV_DIR}"
fi

if [[ -f "${APP_DIR}/requirements.txt" ]]; then
  echo "Installing Python dependencies..." >&2
  sudo -u "${FYC_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel
  sudo -u "${FYC_USER}" "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt"
else
  echo "WARNING: ${APP_DIR}/requirements.txt not found; install dependencies manually." >&2
fi

set -a
# shellcheck disable=SC1090
source "${ENV_DST}"
set +a

if [[ -z "${FYC_CMD:-}" ]]; then
  echo "ERROR: FYC_CMD is not set in ${ENV_DST}." >&2
  echo "Edit the env file to point at the correct FollowYourCanvas launch command." >&2
  exit 1
fi

cp "${SERVICE_SRC}" "${SERVICE_DST}"
chmod 644 "${SERVICE_DST}"

systemctl daemon-reload
systemctl enable "${LABEL}"
systemctl restart "${LABEL}"

if systemctl is-active --quiet "${LABEL}"; then
  echo "FollowYourCanvas is running." >&2
else
  echo "FollowYourCanvas failed to start; check logs with: journalctl -u ${LABEL} -n 100" >&2
  exit 1
fi

if [[ -d "/var/lib/gateway/tools" ]]; then
  echo "Installing gateway tool wrapper..." >&2
  cp "${HERE}/../tools/followyourcanvas_generate.py" /var/lib/gateway/tools/
  chmod 755 /var/lib/gateway/tools/followyourcanvas_generate.py
fi
