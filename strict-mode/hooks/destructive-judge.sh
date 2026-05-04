#!/usr/bin/env bash
# destructive-judge.sh — Phase C semantic helper for pre-destructive.sh.
#
# Когда pattern blacklist + protected-paths не match'нули, но команда подозрительная
# (e.g. `php artisan migrate` running unknown SQL, `curl -X DELETE` API call,
# `bash script.sh` опасный wrapper) — Haiku судья classifies semantically.
#
# Input (stdin JSON): {"command": "...", "cwd": "..."}
# Output (stdout JSON): {"destructive": true|false, "reason": "..."}
# Test mode: env STRICT_DESTRUCTIVE_JUDGE_MOCK=<json> — выводит как есть.
# Никогда не fail loud — fallback {"destructive":false} с exit 0.

set -uo pipefail

INPUT=$(cat)

if [[ -n "${STRICT_DESTRUCTIVE_JUDGE_MOCK:-}" ]]; then
  printf '%s\n' "$STRICT_DESTRUCTIVE_JUDGE_MOCK"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '{"destructive":false,"reason":"jq missing"}\n'
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  printf '{"destructive":false,"reason":"claude CLI unavailable"}\n'
  exit 0
fi

CMD=$(printf '%s' "$INPUT" | jq -r '.command // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[[ -z "$CMD" ]] && { printf '{"destructive":false,"reason":"empty command"}\n'; exit 0; }

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 30"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 30"
fi

PROMPT_TEMPLATE=$(cat <<'EOF'
You are a semantic safety judge for shell commands. Classify if command is DESTRUCTIVE on production data/config (irreversible without backup).

Command:
__CMD_PLACEHOLDER__

Working directory:
__CWD_PLACEHOLDER__

Destructive examples:
- Deletes irreversibly (rm -rf, DROP TABLE, TRUNCATE, kubectl delete)
- Modifies prod config without backup (echo > /etc/, ALTER TABLE)
- Force-overwrites git history (push --force, reset --hard)
- Stops/restarts services without graceful shutdown (systemctl stop/restart on prod)
- Migrations/schema changes without dry-run (php artisan migrate, rake db:migrate, alembic upgrade)
- API calls deleting resources (curl -X DELETE on prod URLs)
- Mass file ops irreversibly (find -delete, dd if=)

Non-destructive:
- Read-only (cat, ls, grep, find without -delete, SELECT)
- Local sandbox/temp ops (rm /tmp/cache, sandbox writes)
- Test/dev DB destructive ops (docker rm test_db is OK)
- Build/compile (cargo build, npm run build)
- Git read ops (status, log, diff, checkout existing branch without --)

Output STRICTLY this JSON (no preamble):
{"destructive": <true|false>, "reason": "<short why>"}
EOF
)

PROMPT="${PROMPT_TEMPLATE//__CMD_PLACEHOLDER__/$CMD}"
PROMPT="${PROMPT//__CWD_PLACEHOLDER__/$CWD}"

JUDGE_TMP_STDOUT=$(mktemp -t destructive-judge.XXXXXX 2>/dev/null) || JUDGE_TMP_STDOUT=/dev/null
JUDGE_TMP_STDERR=$(mktemp -t destructive-judge-err.XXXXXX 2>/dev/null) || JUDGE_TMP_STDERR=/dev/null
trap '[[ "$JUDGE_TMP_STDOUT" != /dev/null ]] && rm -f "$JUDGE_TMP_STDOUT" 2>/dev/null; [[ "$JUDGE_TMP_STDERR" != /dev/null ]] && rm -f "$JUDGE_TMP_STDERR" 2>/dev/null' EXIT

STRICT_MODE_NESTED=1 $TIMEOUT_CMD claude -p --model claude-haiku-4-5-20251001 \
  --strict-mcp-config --tools "" -- "$PROMPT" \
  >"$JUDGE_TMP_STDOUT" 2>"$JUDGE_TMP_STDERR"
EC=$?

if [[ "$EC" -ne 0 ]]; then
  printf '{"destructive":false,"reason":"claude -p failed (exit=%s) — fail-open"}\n' "$EC"
  exit 0
fi

RESULT=$(cat "$JUDGE_TMP_STDOUT" 2>/dev/null)
JSON=$(printf '%s' "$RESULT" | sed -n '/^{/,/^}/p')
[[ -z "$JSON" ]] && JSON=$(printf '%s' "$RESULT" | grep -oE '\{[^}]*"destructive"[^}]*\}' | head -1)
[[ -z "$JSON" ]] && JSON="$RESULT"

if printf '%s' "$JSON" | jq -e '.destructive' >/dev/null 2>&1; then
  printf '%s\n' "$JSON"
else
  printf '{"destructive":false,"reason":"non-JSON judge response"}\n'
fi
exit 0
