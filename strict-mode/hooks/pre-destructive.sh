#!/usr/bin/env bash
# pre-destructive.sh — PreToolUse(Bash) destructive-op gate (Phase A+B).
#
# Blocks Bash commands matching destructive-patterns.txt OR touching paths
# in protected-paths.txt unless one of the bypass mechanisms used:
#   - One-shot bypass file: ~/.claude/state/bypass-destructive-<sid> with reason
#   - Confirmation hash file: ~/.claude/state/confirm-<sid>-<sha256-of-cmd> with
#     reason (Phase B). Hash коммита command — paraphrase обходит.
#   - Per-project opt-out: <project>/.claude/no-destructive-gate
#
# Audit trail: all matches+bypasses → ~/.claude/state/destructive-log.jsonl
#
# Recursion guard: skip on STRICT_MODE_NESTED=1 (nested claude -p calls).

set -uo pipefail

[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0  # fail-open: jq missing — не блокируем
fi

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Только для Bash tool
[[ "$TOOL" != "Bash" ]] && exit 0
[[ -z "$CMD" ]] && exit 0
[[ -z "$SID" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Per-project opt-out
[[ -f "$PROJECT_DIR/.claude/no-destructive-gate" ]] && exit 0

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null

BYPASS_FILE="$STATE_DIR/bypass-destructive-${SID}"
AUDIT_LOG="$STATE_DIR/destructive-log.jsonl"

audit_log() {
  local action="$1" reason="$2"
  local ts
  ts="$(date -Iseconds 2>/dev/null || date)"
  printf '{"ts":"%s","sid":"%s","action":"%s","cmd":%s,"reason":%s}\n' \
    "$ts" "$SID" "$action" \
    "$(printf '%s' "$CMD" | jq -Rs . 2>/dev/null || echo '""')" \
    "$(printf '%s' "$reason" | jq -Rs . 2>/dev/null || echo '""')" \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# === One-shot bypass file (Phase A) ===
if [[ -f "$BYPASS_FILE" ]]; then
  REASON=$(cat "$BYPASS_FILE" 2>/dev/null)
  if [[ -n "$REASON" ]]; then
    audit_log "bypass" "$REASON"
    rm -f "$BYPASS_FILE" 2>/dev/null
    exit 0
  fi
fi

# === Confirmation hash gate (Phase B) ===
# sha256 первых 4096 байт команды (защита от gigantic-cmd hash overflow).
CMD_HASH=$(printf '%s' "$CMD" | head -c 4096 | shasum -a 256 2>/dev/null | awk '{print $1}' | cut -c1-32)
CONFIRM_FILE="$STATE_DIR/confirm-${SID}-${CMD_HASH}"
if [[ -n "$CMD_HASH" && -f "$CONFIRM_FILE" ]]; then
  # CRITICAL: confirm file должен быть создан в ПРЕДЫДУЩЕМ turn (mtime check).
  # Если file moved/created в текущем turn — это self-confirm, не легит.
  # Heuristic: file mtime должен быть > N секунд (не just-now).
  CONFIRM_MTIME=$(stat -c %Y "$CONFIRM_FILE" 2>/dev/null || stat -f %m "$CONFIRM_FILE" 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE=$(( NOW_EPOCH - CONFIRM_MTIME ))
  # Минимум 5 секунд возраста — defeats "create + use в same turn" pattern.
  # User typing "да" → next prompt → hook sees confirm — естественная задержка >> 5s.
  if [[ "$AGE" -ge 5 ]]; then
    REASON=$(cat "$CONFIRM_FILE" 2>/dev/null)
    audit_log "confirm-hash-allow" "age=${AGE}s reason=${REASON}"
    rm -f "$CONFIRM_FILE" 2>/dev/null
    exit 0
  else
    audit_log "confirm-hash-too-fresh" "age=${AGE}s, requires >=5s gap"
    # Fall through — block normally.
  fi
fi

# === Pattern blacklist match ===
GLOBAL_PATTERNS="$HOME/.claude/destructive-patterns.txt"
PROJECT_PATTERNS="$PROJECT_DIR/.claude/destructive-patterns.txt"
COMBINED_PATTERNS=$(mktemp -t destructive-patterns.XXXXXX 2>/dev/null) || COMBINED_PATTERNS=""
if [[ -n "$COMBINED_PATTERNS" ]]; then
  trap 'rm -f "$COMBINED_PATTERNS" 2>/dev/null' EXIT
  [[ -f "$GLOBAL_PATTERNS" ]] && grep -v '^#' "$GLOBAL_PATTERNS" 2>/dev/null | grep -v '^$' >> "$COMBINED_PATTERNS"
  [[ -f "$PROJECT_PATTERNS" ]] && grep -v '^#' "$PROJECT_PATTERNS" 2>/dev/null | grep -v '^$' >> "$COMBINED_PATTERNS"
fi

MATCHED_PATTERN=""
if [[ -s "$COMBINED_PATTERNS" ]]; then
  MATCHED_PATTERN=$(printf '%s' "$CMD" | grep -oiE -f "$COMBINED_PATTERNS" 2>/dev/null | head -1)
fi

# === Protected-path scan ===
GLOBAL_PROTECTED="$HOME/.claude/protected-paths.txt"
PROJECT_PROTECTED="$PROJECT_DIR/.claude/protected-paths.txt"
COMBINED_PROTECTED=$(mktemp -t protected-paths.XXXXXX 2>/dev/null) || COMBINED_PROTECTED=""
if [[ -n "$COMBINED_PROTECTED" ]]; then
  trap '[[ -n "$COMBINED_PATTERNS" ]] && rm -f "$COMBINED_PATTERNS" 2>/dev/null; rm -f "$COMBINED_PROTECTED" 2>/dev/null' EXIT
  [[ -f "$GLOBAL_PROTECTED" ]] && grep -v '^#' "$GLOBAL_PROTECTED" 2>/dev/null | grep -v '^$' >> "$COMBINED_PROTECTED"
  [[ -f "$PROJECT_PROTECTED" ]] && grep -v '^#' "$PROJECT_PROTECTED" 2>/dev/null | grep -v '^$' >> "$COMBINED_PROTECTED"
fi

# Extract path-like tokens из command: что после `>`, `>>`, mv/cp/rm targets, ssh paths.
# Простая heuristic: сплит по space/tab/`,`/`;`/`>`/`<` и filter only path-like tokens.
PROTECTED_HIT=""
if [[ -s "$COMBINED_PROTECTED" ]]; then
  # Извлекаем все subString'ы выглядящие как абс. пути или ~-relative.
  # tr пропускает remaining chars, awk фильтрует по starts-with-/ или ~.
  CMD_TOKENS=$(printf '%s' "$CMD" | tr ';|&<>(){}=' '\n\n\n\n\n\n\n\n\n\n' | tr -s '[:space:]' '\n' | awk '/^(\/|~\/|\.\.\/|\.\/)/ {print}' | sort -u)
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    # Расширяем ~ → $HOME для match
    expanded="${tok/#~/$HOME}"
    if printf '%s\n' "$expanded" | grep -E -q -f "$COMBINED_PROTECTED" 2>/dev/null; then
      PROTECTED_HIT="$tok"
      break
    fi
  done <<< "$CMD_TOKENS"
fi

# === Phase C: Haiku semantic judge (опционально через STRICT_DESTRUCTIVE_JUDGE=1) ===
# Вызывается только если pattern + protected-path БЕЗ match — для catch'а
# semantic destructive: ORM migrate, curl DELETE, opaque wrappers.
# Cost: ~$0.001 per Bash call. Off by default — opt-in.
JUDGE_VERDICT=""
if [[ -z "$MATCHED_PATTERN" && -z "$PROTECTED_HIT" ]] \
   && [[ "${STRICT_DESTRUCTIVE_JUDGE:-0}" = "1" ]] \
   && [[ -x "$HOME/.claude/hooks/destructive-judge.sh" ]]; then
  JUDGE_INPUT=$(jq -n --arg cmd "$CMD" --arg cwd "$PROJECT_DIR" '{command:$cmd, cwd:$cwd}')
  JUDGE_OUT=$(printf '%s' "$JUDGE_INPUT" | "$HOME/.claude/hooks/destructive-judge.sh" 2>/dev/null)
  IS_DESTRUCTIVE=$(printf '%s' "$JUDGE_OUT" | jq -r '.destructive // false' 2>/dev/null)
  if [[ "$IS_DESTRUCTIVE" = "true" ]]; then
    JUDGE_REASON=$(printf '%s' "$JUDGE_OUT" | jq -r '.reason // "(no reason)"' 2>/dev/null)
    JUDGE_VERDICT="$JUDGE_REASON"
  fi
fi

# === Decision ===
if [[ -z "$MATCHED_PATTERN" && -z "$PROTECTED_HIT" && -z "$JUDGE_VERDICT" ]]; then
  # Чисто, exit 0
  exit 0
fi

# Block — формируем reason для модели через stderr (PreToolUse exit 2 → stderr → model)
REASON="🛑 DESTRUCTIVE OP BLOCKED"
[[ -n "$MATCHED_PATTERN" ]] && REASON+=$'\n  matched pattern: '"$MATCHED_PATTERN"
[[ -n "$PROTECTED_HIT" ]] && REASON+=$'\n  protected path: '"$PROTECTED_HIT"
[[ -n "$JUDGE_VERDICT" ]] && REASON+=$'\n  semantic judge: '"$JUDGE_VERDICT"
REASON+=$'\n  command: '"${CMD:0:200}"
REASON+=$'\n\nRequired: ASK USER explicitly: "Подтверждаешь <action>?" — wait for user "да"/"yes" в next message — only THEN retry.'
REASON+=$'\n\nBypass options:'
REASON+=$'\n  1. One-shot file: echo "<reason>" > '"$BYPASS_FILE"
REASON+=$'\n  2. Hash-confirm: echo "<reason>" > '"$STATE_DIR/confirm-${SID}-${CMD_HASH}"' (must be >=5s old)'
REASON+=$'\n  3. Per-project disable: touch '"$PROJECT_DIR/.claude/no-destructive-gate"

audit_log "block" "pattern=${MATCHED_PATTERN:-none}, path=${PROTECTED_HIT:-none}"

printf '%s\n' "$REASON" >&2
exit 2
