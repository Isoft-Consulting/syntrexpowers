#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$SCRIPT_DIR/tools/rollback_runtime.rb" "$@"
