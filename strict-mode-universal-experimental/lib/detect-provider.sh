#!/usr/bin/env sh
set -eu

if [ "${1:-}" = "--provider" ] && [ -n "${2:-}" ]; then
  case "$2" in
    claude|codex) printf '%s\n' "$2"; exit 0 ;;
  esac
fi

case "${STRICT_PROVIDER:-}" in
  claude|codex) printf '%s\n' "$STRICT_PROVIDER"; exit 0 ;;
esac

printf '%s\n' "unknown"
