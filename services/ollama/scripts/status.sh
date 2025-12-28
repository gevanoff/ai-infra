#!/bin/zsh
set -euo pipefail
LABEL="com.ollama.server"
sudo launchctl print system/"$LABEL" | sed -n '1,220p'
