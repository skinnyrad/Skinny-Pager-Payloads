#!/bin/sh
# v28_run.sh — wrapper that execs v28_run.py with the right env.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="/usr/lib:/lib:${LD_LIBRARY_PATH:-}"
exec python3 "$SCRIPT_DIR/v28_run.py" "$@"
