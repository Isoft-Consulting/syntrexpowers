#!/usr/bin/env bash
# Тест для lib/require-ruby.sh — gate'а минимальной версии Ruby.
# Запускает gate с подменённым PATH, в котором лежит shim-ruby печатающий
# заданную RUBY_VERSION. Проверяет:
#   1. version >= floor (2.6) → exit 0
#   2. version < floor → exit 2 + сообщение в stderr
#   3. ruby отсутствует в PATH → exit 2 + сообщение в stderr
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
GATE="$ROOT/lib/require-ruby.sh"

PASS=0
FAIL=0
FAILS=()

assert_pass() {
  local name="$1"
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$name"
}

assert_fail() {
  local name="$1" detail="$2"
  FAIL=$((FAIL + 1))
  FAILS+=("$name")
  printf '  ✗ %s: %s\n' "$name" "$detail"
}

# Сделать временную директорию с shim-ruby который печатает заданную версию.
make_shim() {
  local version="$1" dir
  dir=$(mktemp -d -t require-ruby-shim.XXXXXX)
  cat > "$dir/ruby" <<SHIM
#!/usr/bin/env bash
# Shim ruby — реагирует на -e (eval код) и -v.
# Поддерживаем достаточный subset чтобы lib/require-ruby.sh отработал.
if [[ "\${1:-}" = "-e" ]]; then
  # Заменяем RUBY_VERSION внутри переданного кода на наш литерал и вызываем
  # реальный bash-eval simulator: парсим код вручную для версии.
  # Code shape: 'major, minor = RUBY_VERSION.split(...).first(2).map(&:to_i); exit ...'
  # А также 'print RUBY_VERSION'.
  case "\$2" in
    *"print RUBY_VERSION"*)
      printf '%s' "$version"
      exit 0
      ;;
    *"RUBY_VERSION.split"*)
      # Имитируем интерпретацию: достаём min major/minor из переданного кода.
      MIN_MAJOR=\$(printf '%s' "\$2" | grep -oE 'major > [0-9]+' | head -1 | grep -oE '[0-9]+')
      MIN_MINOR=\$(printf '%s' "\$2" | grep -oE 'minor >= [0-9]+' | head -1 | grep -oE '[0-9]+')
      ACT_MAJOR=\$(printf '%s' "$version" | cut -d. -f1)
      ACT_MINOR=\$(printf '%s' "$version" | cut -d. -f2)
      if (( ACT_MAJOR > MIN_MAJOR )) || (( ACT_MAJOR == MIN_MAJOR && ACT_MINOR >= MIN_MINOR )); then
        exit 0
      else
        exit 1
      fi
      ;;
    *)
      exit 0
      ;;
  esac
fi
exit 0
SHIM
  chmod +x "$dir/ruby"
  printf '%s' "$dir"
}

# === Case 1: ruby >= 2.6 → gate проходит, exit 0 ===
SHIM_OK=$(make_shim "2.6.10")
trap 'rm -rf "$SHIM_OK" "${SHIM_LOW:-}" "${SHIM_NEW:-}"' EXIT
out=$(PATH="$SHIM_OK:/bin:/usr/bin" sh "$GATE" 2>&1); ec=$?
if [[ "$ec" -eq 0 ]]; then
  assert_pass "ruby-2.6.10-passes-gate"
else
  assert_fail "ruby-2.6.10-passes-gate" "exit=$ec, output=$out"
fi

SHIM_NEW=$(make_shim "3.2.0")
out=$(PATH="$SHIM_NEW:/bin:/usr/bin" sh "$GATE" 2>&1); ec=$?
if [[ "$ec" -eq 0 ]]; then
  assert_pass "ruby-3.2.0-passes-gate"
else
  assert_fail "ruby-3.2.0-passes-gate" "exit=$ec, output=$out"
fi

# === Case 2: ruby < 2.6 → gate отклоняет, exit 2 + сообщение ===
SHIM_LOW=$(make_shim "2.5.9")
out=$(PATH="$SHIM_LOW:/bin:/usr/bin" sh "$GATE" 2>&1); ec=$?
if [[ "$ec" -eq 2 ]]; then
  assert_pass "ruby-2.5.9-rejected-exit2"
else
  assert_fail "ruby-2.5.9-rejected-exit2" "expected exit=2, got=$ec, output=$out"
fi
if printf '%s' "$out" | grep -qF "Ruby >= 2.6 required"; then
  assert_pass "ruby-2.5.9-rejected-message"
else
  assert_fail "ruby-2.5.9-rejected-message" "missing diagnostic, got=$out"
fi

# === Case 3: ruby отсутствует в PATH → exit 2 + сообщение ===
EMPTY=$(mktemp -d -t require-ruby-empty.XXXXXX)
# Используем абсолютный путь к sh, чтобы интерпретатор был доступен даже при пустом PATH.
out=$(PATH="$EMPTY" /bin/sh "$GATE" 2>&1); ec=$?
rm -rf "$EMPTY"
if [[ "$ec" -eq 2 ]]; then
  assert_pass "no-ruby-in-PATH-exit2"
else
  assert_fail "no-ruby-in-PATH-exit2" "expected exit=2, got=$ec, output=$out"
fi
if printf '%s' "$out" | grep -qF "ruby executable not found in PATH"; then
  assert_pass "no-ruby-in-PATH-message"
else
  assert_fail "no-ruby-in-PATH-message" "missing diagnostic, got=$out"
fi

if [[ "$FAIL" -eq 0 ]]; then
  printf 'require-ruby gate tests passed (%d cases)\n' "$PASS"
  exit 0
else
  printf 'require-ruby gate tests FAILED (%d of %d cases)\n' "$FAIL" "$((PASS + FAIL))"
  printf '  - %s\n' "${FAILS[@]}"
  exit 1
fi
