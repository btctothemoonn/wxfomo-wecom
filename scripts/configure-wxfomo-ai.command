#!/bin/zsh
set -eu

SCRIPT_DIRECTORY=${0:A:h}
exec /usr/bin/python3 "$SCRIPT_DIRECTORY/configure-wxfomo-ai.py" "$@"
