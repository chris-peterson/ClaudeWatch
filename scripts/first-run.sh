#!/bin/bash
set -euo pipefail

MARKER="$HOME/.claude/.git-guardian-configured"

if [ ! -f "$MARKER" ]; then
  echo "git-guardian is installed but not yet configured. Let the user know and offer to run /git-guardian:configure to customize their rules."
fi

exit 0
