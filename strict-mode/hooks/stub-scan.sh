#!/usr/bin/env bash
# stub-scan.sh — pattern-based stub detector для PHP/Go/JS/TS.
# Modes:
#   stub-scan.sh file <path>      — сканирует файл на диске
#   stub-scan.sh stdin <ext>      — читает stdin как код с указанным расширением
# Exit:
#   0 = clean
#   2 = stubs found (stderr details)
#   1 = неверные аргументы
set -uo pipefail

usage() {
  echo "usage: stub-scan.sh file <path> | stdin <ext>" >&2
  exit 1
}

MODE="${1:-}"
ARG="${2:-}"
[[ -z "$MODE" || -z "$ARG" ]] && usage

case "$MODE" in
  file)
    [[ ! -f "$ARG" ]] && exit 0
    EXT="${ARG##*.}"
    SOURCE="$ARG"
    INPUT_FILE="$ARG"
    USE_VAR=0
    ;;
  stdin)
    EXT="$ARG"
    CONTENT=$(cat)
    SOURCE="<pre-write content>"
    USE_VAR=1
    ;;
  *)
    usage
    ;;
esac

case "$EXT" in
  php|go|js|jsx|ts|tsx|mjs|cjs) ;;
  *) exit 0 ;;
esac

ALLOWLIST="$HOME/.claude/stub-allowlist.txt"
FINDINGS=""

# Фильтруем хиты:
# - строки с маркером `allow-stub:` пропускаются
# - file:line из ALLOWLIST пропускаются (только для MODE=file)
filter_allowed() {
  local hits="$1"
  [[ -z "$hits" ]] && return
  local result=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | grep -q 'allow-stub:'; then continue; fi
    if [[ -f "$ALLOWLIST" && "$MODE" = "file" ]]; then
      local lineno
      lineno=$(echo "$line" | cut -d: -f1)
      if grep -qE "^${SOURCE}:${lineno}:" "$ALLOWLIST" 2>/dev/null; then
        continue
      fi
    fi
    result+="$line"$'\n'
  done <<< "$hits"
  printf '%s' "$result"
}

scan() {
  local pattern="$1" label="$2"
  local hits filtered
  # F26: file-mode grep'ит файл напрямую, не загружая в bash-переменную.
  # stdin-mode держит content в переменной (типично < 100KB после F27 size-limit).
  if [[ "$USE_VAR" = "1" ]]; then
    hits=$(printf '%s\n' "$CONTENT" | grep -nE "$pattern" 2>/dev/null || true)
  else
    hits=$(grep -nE "$pattern" "$INPUT_FILE" 2>/dev/null || true)
  fi
  filtered=$(filter_allowed "$hits")
  if [[ -n "$filtered" ]]; then
    FINDINGS+=$'\n['"$label"$']\n'"$filtered"
  fi
}

# Универсальные маркеры
scan '\b(TODO|FIXME|XXX|HACK)\b' 'TODO/FIXME/XXX/HACK'
scan '(дореал|доделат|допиш|потом сдела|реализу[ею] позже|implement later|fix later)' 'later-marker'

case "$EXT" in
  php)
    scan 'throw[[:space:]]+new[[:space:]]+\\?[A-Za-z_]*Exception\([^)]*(not[[:space:]]+implemented|заглушк|stub|todo)' 'php-not-implemented'
    scan '\bdie\([^)]*(stub|заглушк|todo|not[[:space:]]+implemented)' 'php-die-stub'
    ;;
  go)
    scan 'panic\([[:space:]]*"[^"]*(not[[:space:]]+implemented|TODO|todo|stub|заглушк)' 'go-panic-stub'
    scan '//[[:space:]]*TODO[\(:]' 'go-todo-marker'
    ;;
  js|jsx|ts|tsx|mjs|cjs)
    scan 'throw[[:space:]]+new[[:space:]]+Error\([^)]*(not[[:space:]]+implemented|TODO|stub|заглушк)' 'js-not-implemented'
    ;;
esac

if [[ -n "$FINDINGS" ]]; then
  {
    printf 'STUB-CHECK FAIL: %s\n%s\n' "$SOURCE" "$FINDINGS"
    printf '\nNo stubs allowed (TODO/FIXME/not-implemented/etc).\n'
    printf 'Code must be complete to working state. After implementation — run /fdr.\n'
    printf 'Bypass per-line: append "// allow-stub: <reason>" to that line.\n'
    printf 'Bypass per-file:line: add to ~/.claude/stub-allowlist.txt as "file:line:reason".\n'
  } >&2
  exit 2
fi
exit 0
