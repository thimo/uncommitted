#!/bin/bash
# Remove the demo tree created by setup-screenshots.sh.
set -euo pipefail

DEMO="$HOME/tmp/uncommitted-demo"

if [ ! -d "$DEMO" ]; then
    echo "Nothing to remove — $DEMO doesn't exist."
    exit 0
fi

if command -v trash >/dev/null 2>&1; then
    trash "$DEMO"
    echo "Moved $DEMO to the Trash."
else
    rm -rf "$DEMO"
    echo "Removed $DEMO."
fi
