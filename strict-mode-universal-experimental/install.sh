#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Минимальная поддерживаемая версия Ruby для installer/validators/tests.
# Все утилиты (включая bin/strict-hook) тестируются на Ruby >= 2.6.
RUBY_MIN_MAJOR=2
RUBY_MIN_MINOR=6
if ! ruby -e "
  major, minor = RUBY_VERSION.split('.').first(2).map(&:to_i)
  exit (major > $RUBY_MIN_MAJOR) || (major == $RUBY_MIN_MAJOR && minor >= $RUBY_MIN_MINOR) ? 0 : 1
" >/dev/null 2>&1; then
  ruby_actual=$(ruby -e 'print RUBY_VERSION' 2>/dev/null || printf "missing")
  printf 'strict-mode install: Ruby >= %d.%d required, found %s\n' "$RUBY_MIN_MAJOR" "$RUBY_MIN_MINOR" "$ruby_actual" >&2
  exit 2
fi

exec ruby "$SCRIPT_DIR/tools/install_runtime.rb" "$@"
