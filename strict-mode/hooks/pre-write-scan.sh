#!/usr/bin/env bash
# pre-write-scan.sh — PreToolUse для Write/Edit/MultiEdit.
# Извлекает новый контент из tool_input, прогоняет через stub-scan.sh.
# Exit 2 → блок tool call (Claude Code не запустит Write/Edit/MultiEdit).
set -uo pipefail

# Recursion guard: nested claude -p вызовы — не блокируем file-writes для headless судьи.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required by strict-mode hooks (brew install jq)" >&2
  exit 2
fi

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ -z "$FILE" ]] && exit 0

EXT="${FILE##*.}"
case "$EXT" in
  php|go|js|jsx|ts|tsx|mjs|cjs) ;;
  *) exit 0 ;;
esac

case "$TOOL" in
  Write)     CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty') ;;
  Edit)      CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty') ;;
  MultiEdit) CONTENT=$(printf '%s' "$INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")') ;;
  *)         exit 0 ;;
esac

# F27: size-limit. Большие правки (> ~512KB) не сканируем pre-write — bash-переменная
# с многомегабайтным контентом тормозит каждое Write/Edit. Stop-guard всё равно подберёт
# стабы из файла с диска через эффективный file-mode (после F26 фикса).
# Можно оверрайднуть через env STRICT_PRE_WRITE_MAX_BYTES.
MAX_BYTES="${STRICT_PRE_WRITE_MAX_BYTES:-524288}"
if [[ ${#CONTENT} -gt $MAX_BYTES ]]; then
  echo "[strict-mode] pre-write-scan: content ${#CONTENT}B > ${MAX_BYTES}B limit — skip. stop-guard will scan from disk." >&2
  exit 0
fi

# Прогон в режиме stdin
printf '%s' "$CONTENT" | "$HOME/.claude/hooks/stub-scan.sh" stdin "$EXT"
exit $?
