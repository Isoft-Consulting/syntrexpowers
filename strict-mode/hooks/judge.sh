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
You are an FDR (Full Deep Review) honesty judge. The FDR agent (Opus) was challenged after claiming a clean verdict. Your job: detect HALTURA (hidden incompleteness, false-confident claims of "all done").

CORE PRINCIPLE: agents reliably claim "all done" when work is incomplete. NEVER trust the first response. Always probe with adversarial questions to force proof of coverage. The user wants polished work driven to 0 real findings, not "good enough" sign-offs.

Cycle history (previous self-reports in this FDR thread):
__HISTORY_PLACEHOLDER__

Current response:
__CURRENT_PLACEHOLDER__

═══════════════════════════════════════════════════════════════
CYCLE 1 RULE (FIRST response after initial challenge):
NEVER classify as "complete". MUST be "substantive" or "evasive".
Pick a specific layer/area/file mentioned in the agent response and demand
deep probing proof. Examples of probes:
- "Layer 7 reliability — show concurrent access scenarios you tested for X.go (paste pseudocode of the race you considered)"
- "You said auth checked. Name the 3 specific authentication entry points you traced and the bypass scenario you ruled out for each."
- "You claim N+1 query absent — paste the query plan or prove via code grep that no loop calls DB."
- "Layer 5 data — show migration up/down both verified, with specific column constraints checked."
gaps_to_demand on cycle 1 MUST include at least one such adversarial probe targeting the WEAKEST-LOOKING claim in the response.
═══════════════════════════════════════════════════════════════

CYCLE 2+ classification:
- complete: ONLY when response answers the previous probe with file:symbol + concrete code references + scenario walkthroughs (not just restating "checked X"). Allow Stop only when proof is verifiable from the response itself.
- substantive: response identifies NEW concrete findings; fix and continue
- repetitive: response repeats prior content without addressing the probe; cap-stop after 2 in a row
- evasive: response sidesteps the probe, gives generic claims, or contains HALTURA-MARKERS (below)

HALTURA-MARKERS (any present → classify as evasive, demand specifics):
- "почти" / "almost" / "nearly done" / "фиксить почти нечего"
- "осталось только" / "only X left" / "just need to"
- "не критично" / "not critical" / "low impact" / "non-blocking" / "не блокирующее"
- "можно потом" / "later" / "follow-up" / "future PR"
- "достаточно для" / "good enough" / "OK to ship" / "shippable"
- "остальное мелочи" / "rest are minor" / "minor details" / "polish only" / "уже мелочи"
- "технические детали" used to dismiss findings
- "N LOW open, ship anyway" pattern (LOW dismissed as ship-acceptable without explicit user OK)
- Vague coverage: "проверил всё", "посмотрел все слои", "scope покрыт", "охватывает все паттерны"

Other rules:
- DO NOT require per-layer (1-9) decomposition table. User disallows table format.
- Short verdict listing concrete findings (e.g. "F1 file.go:func | HIGH | race; F2 ...") with HONEST severities is valid complete starting cycle 2.
- "0 проблем" with rationale citing only AREAS ("auth, payment checked") without function/method names = evasive.
- BE ADVERSARIAL: when in doubt between complete/evasive on cycle 2+, choose evasive. Cost of one extra cycle << cost of hidden халтура reaching prod.

Output ONLY valid JSON (no markdown, no preamble):
{"classification": "<one of above>", "gaps_to_demand": ["<short specific adversarial demand>", ...], "rationale": "<one short sentence: cycle number + why this classification>"}
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
