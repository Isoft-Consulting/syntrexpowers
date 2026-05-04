#!/usr/bin/env bash
# prompt-inject.sh — UserPromptSubmit hook.
# Инжектит strict-mode reminder в context на каждом турне.
# Каждые N турнов — re-injects FULL CLAUDE.md / AGENTS.md key rules
# (Phase B-5 anti-context-compression).
set -uo pipefail

# Recursion guard: если nested invocation (claude -p из judge.sh / fdr-verify.sh / триаж),
# не инжектить reminder — иначе вложенный claude видит правила и пытается их применить.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

# === Periodic re-prime (Phase B-5) ===
# Defeat context compression: каждые N турнов инжектируем full key rules
# из CLAUDE.md + AGENTS.md. Counter в state per session.
RE_PRIME_INTERVAL="${STRICT_REPRIME_INTERVAL:-10}"
SID=""
if command -v jq >/dev/null 2>&1; then
  SID=$(cat | jq -r '.session_id // empty' 2>/dev/null || true)
fi
SAFE_SID=$(printf '%s' "$SID" | tr -cd '[:alnum:]-_')
COUNTER_FILE=""
TURN_COUNT=0
if [[ -n "$SAFE_SID" ]]; then
  STATE_DIR="$HOME/.claude/state"
  mkdir -p "$STATE_DIR" 2>/dev/null
  COUNTER_FILE="$STATE_DIR/turn-counter-${SAFE_SID}"
  TURN_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  TURN_COUNT=$((TURN_COUNT + 1))
  echo "$TURN_COUNT" > "$COUNTER_FILE" 2>/dev/null
fi

cat <<'EOF'
[STRICT MODE]
1. No stubs (TODO/FIXME/not implemented). Code complete to working state.
2. After ANY edit (code/docs/config/migrations/specs/README): think through 9 FDR layers internally, fix found issues. NO 9-layer coverage table in chat — only real fixes + brief verdict.
3. Findings (when reported): file (+:symbol when actionable), expected vs actual, severity. Add :line only for CRITICAL/HIGH.
4. Do exactly what's asked. "Изучи" = study, not edit. When unsure, ask.
5. Reply in Russian. Code comments Russian. FDR/briefs English.
6. After code edits final message MUST contain explicit verdict: "0 проблем" + rationale citing 3+ specific file:symbol locations actually inspected (not just areas like "auth/wallet checked"), OR list of open findings (file:symbol + severity — fix them, don't dismiss as "minor"). EXPECT probing question on first cycle: judge will pick weakest claim and demand deep proof (race scenarios, query plans, code grep results). Answer with file:symbol + scenario walkthrough, not restated "checked X". HALTURA-маркеры trigger evasive: "почти", "осталось только", "не критично", "можно потом", "остальное мелочи", "достаточно", "не блокирующее", "polish only", "ship anyway", "минор". User wants polished work to 0 real findings.
7. If Stop hook fired on meta-discussion (no actual FDR work in this turn) — reply with the phrase "meta-discussion, no FDR work" in a SHORT message (≤300 chars total) to self-bypass once.
8. **DESTRUCTIVE OPS GATE**: Before any rm/DROP/DELETE/ALTER/restart/migrate/force-push/checkout-discard — explicitly ASK USER "Подтверждаешь <action>?" and WAIT for user "да"/"yes" before executing. NEVER batch destructive without per-op confirm. PreToolUse hook will block destructive Bash commands (matched against ~/.claude/destructive-patterns.txt + protected-paths.txt) — bypass requires conscious echo to ~/.claude/state/bypass-destructive-<sid>. Confirmation hash files must be ≥5s old (defeats self-confirm).
EOF

# === Periodic re-prime block (every Nth turn) ===
if [[ "$TURN_COUNT" -gt 0 ]] && [[ $((TURN_COUNT % RE_PRIME_INTERVAL)) -eq 0 ]]; then
  echo ""
  echo "[STRICT MODE — periodic re-prime, turn #$TURN_COUNT]"
  echo "Context может быть compressed. Re-grounding на ключевые правила:"
  echo ""
  # Re-prime CLAUDE.md (global)
  if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    SIZE=$(wc -c < "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo 0)
    if [[ "${SIZE:-0}" -lt 8192 ]]; then
      echo "=== ~/.claude/CLAUDE.md (full) ==="
      cat "$HOME/.claude/CLAUDE.md"
    else
      echo "=== ~/.claude/CLAUDE.md (truncated to 8KB) ==="
      head -c 8192 "$HOME/.claude/CLAUDE.md"
      echo ""
      echo "[... truncated; full at ~/.claude/CLAUDE.md ...]"
    fi
  fi
  # Re-prime project AGENTS.md if exists
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  if [[ -f "$PROJECT_DIR/AGENTS.md" ]]; then
    SIZE=$(wc -c < "$PROJECT_DIR/AGENTS.md" 2>/dev/null || echo 0)
    if [[ "${SIZE:-0}" -lt 8192 ]]; then
      echo ""
      echo "=== <project>/AGENTS.md (full) ==="
      cat "$PROJECT_DIR/AGENTS.md"
    else
      echo ""
      echo "=== <project>/AGENTS.md (truncated to 8KB) ==="
      head -c 8192 "$PROJECT_DIR/AGENTS.md"
      echo ""
      echo "[... truncated; full at AGENTS.md ...]"
    fi
  fi
fi

exit 0
