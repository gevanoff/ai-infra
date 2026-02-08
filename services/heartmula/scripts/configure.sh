#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="heartmula"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_TEMPLATE="${SERVICE_DIR}/env/heartmula.env.example"
ENV_DIR="/etc/heartmula"
ENV_FILE="/etc/heartmula/heartmula.env"

note() {
  echo "[$SERVICE_NAME] $*" >&2
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts="$(date +"%Y%m%d%H%M%S")"
    local backup="${file}.bak.${ts}"
    cp "$file" "$backup"
    note "Backed up ${file} -> ${backup}"
  fi
}

get_existing_value() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print $0; exit}' "$ENV_FILE" || true
  fi
}

render_env_file() {
  local tmp_file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local existing
      existing="$(get_existing_value "$key")"
      if [[ -n "$existing" ]]; then
        echo "${key}=${existing}" >>"$tmp_file"
      else
        echo "$line" >>"$tmp_file"
      fi
    else
      echo "$line" >>"$tmp_file"
    fi
  done <"$ENV_TEMPLATE"
}

ensure_env() {
  if [[ ! -f "$ENV_TEMPLATE" ]]; then
    note "ERROR: env template missing at ${ENV_TEMPLATE}"
    exit 1
  fi

  mkdir -p "$ENV_DIR"
  local tmp
  tmp="$(mktemp)"

  render_env_file "$tmp"

  backup_file "$ENV_FILE"
  mv "$tmp" "$ENV_FILE"
  note "Configured ${ENV_FILE} from template ${ENV_TEMPLATE}"
}

ensure_env
