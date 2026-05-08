#!/usr/bin/env sh
# Общий gate минимальной версии Ruby для всех shell-обёрток strict-mode.
# Source'ится через `. "$SCRIPT_DIR/lib/require-ruby.sh"` из install.sh,
# uninstall.sh, rollback.sh и tests/run-tests.sh — единая точка истины.

# Минимальная поддерживаемая версия Ruby для installer/validators/tests.
# Все утилиты (включая bin/strict-hook) тестируются на Ruby >= 2.6.
STRICT_MODE_RUBY_MIN_MAJOR=2
STRICT_MODE_RUBY_MIN_MINOR=6

if ! command -v ruby >/dev/null 2>&1; then
  printf 'strict-mode: ruby executable not found in PATH (need >= %d.%d)\n' \
    "$STRICT_MODE_RUBY_MIN_MAJOR" "$STRICT_MODE_RUBY_MIN_MINOR" >&2
  exit 2
fi

if ! ruby -e "
  major, minor = RUBY_VERSION.split('.').first(2).map(&:to_i)
  exit (major > $STRICT_MODE_RUBY_MIN_MAJOR) || (major == $STRICT_MODE_RUBY_MIN_MAJOR && minor >= $STRICT_MODE_RUBY_MIN_MINOR) ? 0 : 1
" >/dev/null 2>&1; then
  ruby_actual=$(ruby -e 'print RUBY_VERSION' 2>/dev/null || printf "missing")
  printf 'strict-mode: Ruby >= %d.%d required, found %s\n' \
    "$STRICT_MODE_RUBY_MIN_MAJOR" "$STRICT_MODE_RUBY_MIN_MINOR" "$ruby_actual" >&2
  exit 2
fi
