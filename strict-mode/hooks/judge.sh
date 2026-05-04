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
You are an FDR (Full Deep Review) honesty judge. The FDR agent (Opus) was challenged after claiming a clean verdict. Your job: drive an iterative "where did you cut corners?" loop until the agent has either fixed all halтура or explicitly framed remaining items as out-of-scope.

CORE PRINCIPLE: do NOT demand technical proof (code paste, scenarios, query plans). Instead, repeatedly ask the SIMPLE psychological trigger: "Где ты схалтурил?" / "Where did you cut corners?". This phrasing is unusually effective — agents readily list cut corners when asked directly, but hide them under confident verdicts otherwise. Once they list, force fixes (or accept explicit out-of-scope reasoning).

Cycle history (previous self-reports in this FDR thread):
__HISTORY_PLACEHOLDER__

Current response:
__CURRENT_PLACEHOLDER__

═══════════════════════════════════════════════════════════════
CYCLE 1 RULE (FIRST response after initial challenge):
NEVER classify as "complete". MUST be "substantive".
gaps_to_demand MUST be exactly: ["Где ты схалтурил? Перечисли конкретно: что упростил, что пропустил, что оставил недоделанным, какие edge cases не проверил."]
rationale: "Cycle 1: triggering 'where did you cut corners?' question to elicit honest списка халтуры."
═══════════════════════════════════════════════════════════════

CYCLE 2+ classification (analyze the agent response for halтура list):

PATH A — agent listed cut-corners (e.g. "Схалтурил тут: ...", "Пропустил X, Y", "Не проверил Z"):
  Step 1: Check each listed item for OUT-OF-SCOPE justification phrases:
    - "вне текущего scope" / "out of current scope"
    - "будет в следующем PR/коммите/задаче" / "follow-up PR"
    - "избыточно для этой задачи" / "redundant for this task"
    - "явно не входит в задачу" / "explicitly not part of the task"
    - "по дизайну не делается" / "by design"
    - "пользователь явно сказал не делать"
  Step 2:
    - If ALL listed items have explicit out-of-scope justification → classification = "complete", rationale = "Agent listed cut corners with valid scope justification."
    - If ANY listed item has NO scope justification → classification = "substantive", gaps_to_demand = ["Давай исправлять. Конкретно: " + список items без out-of-scope обоснования]
  Step 3: After fix-cycle, repeat: gaps_to_demand on next cycle includes "Где ещё ты схалтурил?" to recurse.

PATH B — agent claims no halтура (e.g. "Не схалтурил, всё сделано", "0 проблем"):
  classification = "evasive"
  gaps_to_demand = ["Не верю. Где ты схалтурил? Перечисли что упростил, пропустил, не доделал, какие edge cases пропустил. Если действительно ничего — объясни какие конкретно vulnerable spots ты проверил вручную и почему уверен что они clean."]
  rationale = "Cycle N: agent denies халтура — pushing harder."

PATH C — agent dismisses items as halтура-markers ("почти", "остальное мелочи", "не критично", "достаточно", "polish only", "ship anyway", "минор"):
  classification = "evasive"
  gaps_to_demand = ["Эти 'мелочи'/'не критично' — подозрительная формулировка. Перечисли каждое такое item конкретно: что именно осталось, почему ты считаешь это minor, и фикси если оно в scope. Если out-of-scope — обоснуй."]
  rationale = "Cycle N: халтура-marker dismissal detected — demanding specifics."

PATH D — agent repeats prior халтура list without fixing:
  classification = "repetitive"
  gaps_to_demand = ["Ты уже перечислял эти items в прошлом cycle. Либо фикси либо обоснуй out-of-scope явно для каждого."]
  After 2 repetitive in a row → cap-stop (controller releases).

Other rules:
- DO NOT require per-layer (1-9) decomposition table. User disallows table format.
- DO NOT demand technical proof (code paste, scenarios, query plans) — that is adversarial probing, NOT this judge mode. Use the simple psychological trigger.
- BE ADVERSARIAL on PATH B/C: agents will resist admitting халтура — push harder.
- Honest "схалтурил тут и тут, fix coming" → substantive (not evasive). Do not punish admission.

Output ONLY valid JSON (no markdown, no preamble):
{"classification": "<complete|substantive|repetitive|evasive>", "gaps_to_demand": ["<demand text>", ...], "rationale": "<one short sentence: cycle number + path letter + why>"}
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
