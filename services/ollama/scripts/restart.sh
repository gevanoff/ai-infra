#!/bin/zsh
set -euo pipefail
LABEL="com.ollama.server"
sudo launchctl kickstart -k system/"$LABEL"
