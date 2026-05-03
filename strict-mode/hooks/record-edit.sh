#!/usr/bin/env bash
# record-edit.sh — PostToolUse для Write/Edit/MultiEdit.
# Записывает абсолютный путь правки в ~/.claude/state/edits-<sid>.log.
# ВСЕГДА exit 0 (PostToolUse не должен ломать tool result, см. spec F11/§3.0).
set -uo pipefail

# Recursion guard: nested claude -p вызовы — не записываем edits headless судьи.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

soft_log() {
  local sid="${1:-unknown}"
  local msg="$2"
  mkdir -p "$HOME/.claude/state" 2>/dev/null || return 0
  printf '%s\trecord-edit\t%s\n' "$(date -Iseconds 2>/dev/null || date)" "$msg" \
    >> "$HOME/.claude/state/hook-errors-${sid}.log" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
  soft_log "unknown" "jq missing"
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
PARENT_SID=$(printf '%s' "$INPUT" | jq -r '.parent_session_id // empty')
[[ -z "$PARENT_SID" ]] && PARENT_SID="${CLAUDE_PARENT_SESSION_ID:-}"

[[ -z "$SESSION_ID" || -z "$FILE" ]] && exit 0

mkdir -p "$HOME/.claude/state" 2>/dev/null || exit 0

# Subagent: пишем в parent edits-log если parent_sid известен.
TARGET_SID="$SESSION_ID"
if [[ -n "$PARENT_SID" && "$PARENT_SID" != "$SESSION_ID" ]]; then
  TARGET_SID="$PARENT_SID"
fi

echo "$FILE" >> "$HOME/.claude/state/edits-${TARGET_SID}.log" 2>/dev/null || \
  soft_log "$SESSION_ID" "failed to append edit"

# Если subagent без parent_sid — orphan-лог для возможной агрегации parent'ом по mtime.
if [[ -z "$PARENT_SID" ]] || [[ "$PARENT_SID" = "$SESSION_ID" ]]; then
  : # main session, ничего дополнительного не пишем
else
  : # parent_sid известен, уже записали в parent log
fi

# Если харнесс не пробросил parent_sid и это subagent — orphan log
# (детект subagent'а — heuristic: будем считать что main session это первая активная,
#  но без явного indicator это сложно. Минимум: если есть переменная окружения
#  CLAUDE_SUBAGENT=1 или transcript_path указывает на подсессию — логируем orphan)
if [[ -z "$PARENT_SID" && "${CLAUDE_SUBAGENT:-}" = "1" ]]; then
  printf '%s\t%s\t%s\n' "$(date +%s)" "$SESSION_ID" "$FILE" \
    >> "$HOME/.claude/state/orphan-edits.log" 2>/dev/null || true
fi

exit 0
