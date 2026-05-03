#!/usr/bin/env bash
# stop-guard.sh — Stop / SubagentStop hook.
# Wave 2 minimal: сканирует файлы сессии на стабы, блокирует Stop при находках.
# Wave 3 расширит до FDR-артефакт-гейта + sensitive-verifier.
set -uo pipefail

# Recursion guard: nested claude -p вызовы — skip Stop-валидацию для headless судьи.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required (brew install jq)" >&2
  exit 2
fi

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[[ -z "$SID" ]] && exit 0

EDITS_LOG="$HOME/.claude/state/edits-${SID}.log"
[[ ! -f "$EDITS_LOG" ]] && exit 0

# Bypass-механизм (одноразовый): создан файл ~/.claude/state/bypass-<sid> с reason.
BYPASS_FILE="$HOME/.claude/state/bypass-${SID}"
if [[ -f "$BYPASS_FILE" ]]; then
  REASON=$(cat "$BYPASS_FILE" 2>/dev/null)
  if [[ -n "$REASON" ]]; then
    mkdir -p "$HOME/.claude/state"
    printf '{"timestamp":"%s","session_id":"%s","reason":%s,"phase":"wave2"}\n' \
      "$(date -Iseconds)" "$SID" "$(printf '%s' "$REASON" | jq -Rs '.')" \
      >> "$HOME/.claude/state/bypass-log.jsonl" 2>/dev/null || true
    rm -f "$BYPASS_FILE" 2>/dev/null || true
    exit 0
  fi
fi

PROBLEMS=""
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  OUT=$("$HOME/.claude/hooks/stub-scan.sh" file "$f" 2>&1 >/dev/null) || true
  if [[ -n "$OUT" ]]; then
    PROBLEMS+=$'\n'"$OUT"
  fi
done < <(sort -u "$EDITS_LOG")

if [[ -n "$PROBLEMS" ]]; then
  REASON="Session contains files with stubs/TODO. Complete the code before ending the turn.${PROBLEMS}"
  REASON+=$'\n\nBypass: echo "<reason>" > ~/.claude/state/bypass-'"${SID}"
  jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
fi
exit 0
