#!/bin/zsh
set -euo pipefail

LABEL="com.ai.gateway"
sudo launchctl kickstart -k system/"$LABEL"
