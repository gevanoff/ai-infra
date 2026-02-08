#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="heartmula"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

note() {
  echo "[$SERVICE_NAME] $*" >&2
}

"${SCRIPT_DIR}/configure.sh"
"${SCRIPT_DIR}/restart.sh"
note "Deploy complete"
