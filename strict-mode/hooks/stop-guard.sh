#!/usr/bin/env bash
# stop-guard.sh — Stop / SubagentStop hook.
# Wave 2: stub-scan на сессионных файлах.
# Wave 3 extensions (idempotent — no-op если соответствующая фаза не установлена):
#   (a) edits-log непустой + НЕТ артефакта + не trivial-diff → block "invoke /fdr"
#   (b) артефакт есть → fdr-validate.sh → пробросить findings
#   (c) артефакт + open findings + mtime(edits-log) > mtime(artifact) → auto-block recheck
#   (d) sensitive-paths detected → fdr-verify.sh (Phase 5, заглушка пока)
set -uo pipefail

# Recursion guard: nested claude -p вызовы — skip для headless судьи.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required (brew install jq)" >&2
  exit 2
fi

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[[ -z "$SID" ]] && exit 0

STATE_DIR="$HOME/.claude/state"
HOOKS_DIR="$HOME/.claude/hooks"
EDITS_LOG="$STATE_DIR/edits-${SID}.log"
FDR_ARTIFACT="$STATE_DIR/fdr-${SID}.md"
BYPASS_FILE="$STATE_DIR/bypass-${SID}"

# Bypass — clear + exit (одноразовый, перебивает все остальные проверки)
if [[ -f "$BYPASS_FILE" ]]; then
  REASON=$(cat "$BYPASS_FILE" 2>/dev/null)
  if [[ -n "$REASON" ]]; then
    mkdir -p "$STATE_DIR"
    printf '{"timestamp":"%s","session_id":"%s","reason":%s,"phase":"stop-guard"}\n' \
      "$(date -Iseconds)" "$SID" "$(printf '%s' "$REASON" | jq -Rs '.')" \
      >> "$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    rm -f "$BYPASS_FILE" 2>/dev/null || true
    exit 0
  fi
fi

# Если edits-log не существует — нет работы, ничего проверять.
[[ ! -f "$EDITS_LOG" ]] && exit 0

# === Wave 2: stub-scan ===
PROBLEMS=""
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  OUT=$("$HOOKS_DIR/stub-scan.sh" file "$f" 2>&1 >/dev/null) || true
  [[ -n "$OUT" ]] && PROBLEMS+=$'\n'"$OUT"
done < <(sort -u "$EDITS_LOG")

# Aggregate reasons из всех Wave 3 проверок
BLOCK_REASONS=()

if [[ -n "$PROBLEMS" ]]; then
  BLOCK_REASONS+=("Session contains files with stubs/TODO. Complete the code before ending the turn.${PROBLEMS}")
fi

# === Wave 3 extensions ===

# (b) Артефакт существует → run fdr-validate.sh
ARTIFACT_VALID=true
ARTIFACT_EXISTS=false
if [[ -s "$FDR_ARTIFACT" ]]; then
  ARTIFACT_EXISTS=true
  if [[ -x "$HOOKS_DIR/fdr-validate.sh" ]]; then
    VAL_OUT=$("$HOOKS_DIR/fdr-validate.sh" "$FDR_ARTIFACT" "$EDITS_LOG" "$SID" 2>&1)
    VAL_EC=$?
    if [[ "$VAL_EC" -ne 0 ]]; then
      ARTIFACT_VALID=false
      BLOCK_REASONS+=("FDR artifact ($FDR_ARTIFACT) failed validation:\n$VAL_OUT")
    fi
  fi
fi

# (a) edits-log непустой + НЕТ артефакта + не trivial-diff → block "invoke /fdr"
if ! $ARTIFACT_EXISTS && [[ -s "$EDITS_LOG" ]]; then
  TRIVIAL=false
  if [[ -x "$HOOKS_DIR/is-trivial-diff.sh" ]]; then
    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
    if (cd "$PROJECT_DIR" && "$HOOKS_DIR/is-trivial-diff.sh" >/dev/null 2>&1); then
      TRIVIAL=true
    fi
  fi
  if ! $TRIVIAL; then
    BLOCK_REASONS+=("FDR artifact missing: $FDR_ARTIFACT does not exist or is empty. Edits in this session require an FDR review. Run /fdr to generate the artifact, then end the turn.")
  fi
fi

# (c) Артефакт + open findings + edits-log mtime > artifact mtime → auto-block recheck
if $ARTIFACT_EXISTS && $ARTIFACT_VALID; then
  # Парсим counts из артефакта (Verdict block)
  OPEN_COUNT=$(awk '/^## Verdict$/{f=1;next} /^## /&&f{exit} f && /^counts:/{
    match($0, /[0-9]+[[:space:]]+open/); if (RSTART) print substr($0, RSTART, RLENGTH); exit
  }' "$FDR_ARTIFACT" | awk '{print $1}')
  OPEN_COUNT=${OPEN_COUNT:-0}
  if [[ "$OPEN_COUNT" -gt 0 ]]; then
    EDITS_MTIME=$(stat -f %m "$EDITS_LOG" 2>/dev/null || stat -c %Y "$EDITS_LOG" 2>/dev/null || echo 0)
    ART_MTIME=$(stat -f %m "$FDR_ARTIFACT" 2>/dev/null || stat -c %Y "$FDR_ARTIFACT" 2>/dev/null || echo 0)
    if [[ "$EDITS_MTIME" -gt "$ART_MTIME" ]]; then
      BLOCK_REASONS+=("Open findings ($OPEN_COUNT) + new edits detected after FDR artifact (edits mtime > artifact mtime). Invoke /fdr to recheck.")
    fi
  fi
fi

# (d) Sensitive verifier — Phase 5 hook (no-op без is-sensitive.sh / fdr-verify.sh).
if [[ -x "$HOOKS_DIR/is-sensitive.sh" && -x "$HOOKS_DIR/fdr-verify.sh" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    if "$HOOKS_DIR/is-sensitive.sh" "$f" 2>/dev/null; then
      VERIFY_OUT=$("$HOOKS_DIR/fdr-verify.sh" "$FDR_ARTIFACT" "$EDITS_LOG" 2>&1) || true
      if [[ -n "$VERIFY_OUT" && "$VERIFY_OUT" != *"0 missed"* ]]; then
        BLOCK_REASONS+=("Sensitive-path verifier found gaps:\n$VERIFY_OUT")
      fi
      break
    fi
  done < <(sort -u "$EDITS_LOG")
fi

# Aggregate decision
if [[ ${#BLOCK_REASONS[@]} -gt 0 ]]; then
  COMBINED=""
  for r in "${BLOCK_REASONS[@]}"; do
    [[ -n "$COMBINED" ]] && COMBINED+=$'\n---\n'
    COMBINED+="$r"
  done
  COMBINED+=$'\n\nBypass: echo "<reason>" > '"$BYPASS_FILE"
  jq -n --arg r "$COMBINED" '{decision:"block", reason:$r}'
fi
exit 0
