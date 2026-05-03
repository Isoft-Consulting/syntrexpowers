#!/usr/bin/env bash
# judge.sh — Haiku-classifier FDR challenge response.
# Input  (stdin JSON): {history: [...], current_response: "..."}
# Output (stdout JSON): {classification, gaps_to_demand, rationale}
# Test mode: env STRICT_JUDGE_MOCK_RESPONSE=<json> — выводит как есть.
# Real mode: вызывает claude -p с моделью haiku через timeout 50s
# (10s buffer ниже Stop hook timeout 60000ms из settings.json).
# Никогда не падает loud — fallback "unknown" с exit 0.
set -uo pipefail

INPUT=$(cat)

if [[ -n "${STRICT_JUDGE_MOCK_RESPONSE:-}" ]]; then
  printf '%s\n' "$STRICT_JUDGE_MOCK_RESPONSE"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '{"classification":"unknown","gaps_to_demand":[],"rationale":"jq missing"}\n'
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  printf '{"classification":"unknown","gaps_to_demand":[],"rationale":"claude CLI unavailable"}\n'
  exit 0
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 50"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 50"
fi

HISTORY=$(printf '%s' "$INPUT" | jq -r '.history // [] | tostring' 2>/dev/null)
CURRENT=$(printf '%s' "$INPUT" | jq -r '.current_response // ""' 2>/dev/null)

if [[ -z "$CURRENT" ]]; then
  printf '{"classification":"unknown","gaps_to_demand":[],"rationale":"empty current_response"}\n'
  exit 0
fi

# CRITICAL: quoted heredoc ('EOF') + placeholder substitution.
# Без кавычек внутри $(cat <<EOF ...) bash парсит '...' и "..." → unmatched quote
# в "weren't" / "no impact" ломает скрипт целиком. Quoted heredoc отключает любую
# интерпретацию — текст остаётся литералом. HISTORY/CURRENT inject'им через bash
# string substitution ПОСЛЕ heredoc, что также безопаснее (никакой shell-evaluation
# на пользовательских данных в prompt'е).
PROMPT_TEMPLATE=$(cat <<'EOF'
You are an FDR (Full Deep Review) honesty judge. The FDR agent (Opus) was challenged after claiming a clean verdict. Read the cycle history and current response, classify HONESTY of the report — NOT formatting.

Cycle history (previous self-reports in this FDR thread):
__HISTORY_PLACEHOLDER__

Current response:
__CURRENT_PLACEHOLDER__

Classify into ONE of:
- complete: response shows honest review — either (a) lists concrete open findings (file:symbol + severity), OR (b) states "0 проблем" / "0 problems" WITH a brief substantive rationale (1-3 sentences naming what was actually checked: edge cases, integration points, security boundary, etc — not just "all good"). Per-layer table is NOT required, but bare verdict without rationale is NOT complete. allow Stop only when (a) or (b) satisfied.
- substantive: response identifies NEW concrete findings (file:symbol references, scenarios) that were not in history; should fix and continue
- repetitive: response repeats same findings from history with different wording, no new progress; cap-stop after 2 in a row
- evasive: response gives generic claims without file:symbol or concrete scenarios; demand specifics

Rules:
- DO NOT require per-layer (1-9) decomposition table. User explicitly disallows table-style output.
- Short verdict listing open findings (e.g. "F1 file.go:func | LOW | desc; F2 ...") is VALID complete.
- "0 проблем" verdict is complete ONLY IF accompanied by 1-3 sentence rationale naming concrete things checked. Bare "0 проблем" with no rationale → classify as evasive, demand specifics.
- substantive ONLY when response contains genuinely new findings beyond history.
- evasive ONLY when response is vague hand-wave with no actionable specifics.

Output ONLY valid JSON (no markdown, no preamble):
{"classification": "<one of above>", "gaps_to_demand": ["<short specific demand>", ...], "rationale": "<one short sentence>"}
EOF
)
PROMPT="${PROMPT_TEMPLATE//__HISTORY_PLACEHOLDER__/$HISTORY}"
PROMPT="${PROMPT//__CURRENT_PLACEHOLDER__/$CURRENT}"

JUDGE_STDERR_LOG="$HOME/.claude/state/judge-stderr.log"
mkdir -p "$(dirname "$JUDGE_STDERR_LOG")" 2>/dev/null || JUDGE_STDERR_LOG=/dev/null
JUDGE_TS="$(date -Iseconds 2>/dev/null || date)"
# Capture stdout AND stderr separately to see what claude actually said even on exit≠0.
# Fallback на /dev/null если mktemp fails (ENOSPC / $TMPDIR unwritable) — теряем диагностику,
# но скрипт не падает на ambiguous redirect.
JUDGE_TMP_STDOUT=$(mktemp -t judge-stdout.XXXXXX 2>/dev/null) || JUDGE_TMP_STDOUT=/dev/null
JUDGE_TMP_STDERR=$(mktemp -t judge-stderr.XXXXXX 2>/dev/null) || JUDGE_TMP_STDERR=/dev/null
trap '[[ "$JUDGE_TMP_STDOUT" != /dev/null ]] && rm -f "$JUDGE_TMP_STDOUT" 2>/dev/null; [[ "$JUDGE_TMP_STDERR" != /dev/null ]] && rm -f "$JUDGE_TMP_STDERR" 2>/dev/null' EXIT
# --strict-mcp-config (без --mcp-config) → ноль MCP servers; --tools "" → ноль built-in tools.
# Без этого один из user'овских MCP plugins может содержать tool со схемой `oneOf/allOf/anyOf`
# на верхнем уровне → Anthropic API возвращает 400 invalid_request_error → judge fail.
# Судье tools не нужны — он только классифицирует текст.
STRICT_MODE_NESTED=1 $TIMEOUT_CMD claude -p --model claude-haiku-4-5-20251001 \
  --strict-mcp-config --tools "" -- "$PROMPT" \
  >"$JUDGE_TMP_STDOUT" 2>"$JUDGE_TMP_STDERR"
CLAUDE_EXIT=$?
if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  {
    printf '\n--- judge fail %s exit=%s timeout_cmd="%s" ---\n' "$JUDGE_TS" "$CLAUDE_EXIT" "$TIMEOUT_CMD"
    printf '[stderr]\n'
    cat "$JUDGE_TMP_STDERR" 2>/dev/null
    printf '\n[stdout (first 500 chars)]\n'
    head -c 500 "$JUDGE_TMP_STDOUT" 2>/dev/null
    printf '\n[prompt size]\n%s bytes\n' "$(printf '%s' "$PROMPT" | wc -c | tr -d ' ')"
  } >> "$JUDGE_STDERR_LOG" 2>/dev/null
  printf '{"classification":"unknown","gaps_to_demand":[],"rationale":"claude -p failed (exit=%s, see judge-stderr.log)"}\n' "$CLAUDE_EXIT"
  exit 0
fi
RESULT=$(cat "$JUDGE_TMP_STDOUT" 2>/dev/null)

JSON=$(printf '%s' "$RESULT" | sed -n '/^{/,/^}/p')
# F1 fallback: если JSON не на отдельной строке, ищем inline {...}
if [[ -z "$JSON" ]]; then
  JSON=$(printf '%s' "$RESULT" | grep -oE '\{[^}]*"classification"[^}]*\}' | head -1)
fi
[[ -z "$JSON" ]] && JSON="$RESULT"

if printf '%s' "$JSON" | jq -e '.classification' >/dev/null 2>&1; then
  printf '%s\n' "$JSON"
else
  printf '{"classification":"unknown","gaps_to_demand":[],"rationale":"non-JSON response from haiku"}\n'
fi
exit 0
