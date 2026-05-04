#!/usr/bin/env bash
# static-prepass.sh — Wave 3 Phase 4 PostToolUse hook.
# Запускает доступные static analyzers (phpstan/staticcheck/go vet/eslint/tsc)
# на правленом файле как фон, пишет результат в state/.
#
# Hook contract:
#   - Запускается в PostToolUse(Write|Edit|MultiEdit)
#   - stdin JSON содержит .session_id, .tool_input.file_path
#   - ВСЕГДА exit 0 (PostToolUse не должен ломать tool result, см. spec §3.0)
#   - Tool result не ждёт — analyzer запускается nohup, hook сразу exit'ит
#
# Output:
#   - prepass-<sid>-<safe-path>-<analyzer>.log — output + exit code
#   - prepass-<sid>-<safe-path>-<analyzer>.log.lock — lock file (creator/cleaner contract)
#
# Aggregation: /fdr skill (Phase 3) собирает все prepass-<sid>-*.log в Layer 0
# артефакта через `cat` + parse.
#
# Recursion guard: STRICT_MODE_NESTED=1 → skip (nested claude -p calls).
# Per-project opt-out: <project>/.claude/no-static-prepass — phpstan может выполнять
# arbitrary code (bootstrap files), на untrusted-репозиториях отключать (spec §4.3.1).

set -uo pipefail

# Recursion guard
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[[ -z "$SID" || -z "$FILE" || ! -f "$FILE" ]] && exit 0

# Per-project opt-out
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -f "$PROJECT_DIR/.claude/no-static-prepass" ]] && exit 0

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Sanitized path для имени лога: tr '/' '_' + strip non-alnum чтобы избежать collisions
# между app/auth/utils.php и app/payment/utils.php (basename бы их склеил).
SAFE_PATH=$(printf '%s' "$FILE" | tr '/' '_' | tr -cd '[:alnum:]._-' | head -c 200)

# Определяем какие analyzers применимы по расширению + наличию деп.
EXT="${FILE##*.}"
ANALYZERS=()

case "$EXT" in
  php)
    # phpstan если установлен в проекте (vendor/bin/phpstan)
    if [[ -x "$PROJECT_DIR/vendor/bin/phpstan" ]]; then
      ANALYZERS+=("phpstan")
    fi
    ;;
  go)
    # go vet всегда если go-проект
    if [[ -f "$PROJECT_DIR/go.mod" ]] && command -v go >/dev/null 2>&1; then
      ANALYZERS+=("go-vet")
    fi
    # staticcheck если в PATH
    if command -v staticcheck >/dev/null 2>&1; then
      ANALYZERS+=("staticcheck")
    fi
    ;;
  ts|tsx)
    if [[ -f "$PROJECT_DIR/tsconfig.json" ]] && (command -v tsc >/dev/null 2>&1 || [[ -x "$PROJECT_DIR/node_modules/.bin/tsc" ]]); then
      ANALYZERS+=("tsc")
    fi
    if [[ -f "$PROJECT_DIR/.eslintrc.json" || -f "$PROJECT_DIR/.eslintrc.js" || -f "$PROJECT_DIR/.eslintrc" ]] && (command -v eslint >/dev/null 2>&1 || [[ -x "$PROJECT_DIR/node_modules/.bin/eslint" ]]); then
      ANALYZERS+=("eslint")
    fi
    ;;
  js|jsx|mjs|cjs)
    if [[ -f "$PROJECT_DIR/.eslintrc.json" || -f "$PROJECT_DIR/.eslintrc.js" || -f "$PROJECT_DIR/.eslintrc" ]] && (command -v eslint >/dev/null 2>&1 || [[ -x "$PROJECT_DIR/node_modules/.bin/eslint" ]]); then
      ANALYZERS+=("eslint")
    fi
    ;;
  *)
    exit 0  # неподдерживаемое расширение
    ;;
esac

[[ ${#ANALYZERS[@]} -eq 0 ]] && exit 0  # деп нет — silent skip

# Timeout: 20 sec на analyzer (spec §4.3.1)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 20"
fi

# Запуск каждого аналайзера в фоне, lock + log per analyzer.
for analyzer in "${ANALYZERS[@]}"; do
  LOG_FILE="$STATE_DIR/prepass-${SID}-${SAFE_PATH}-${analyzer}.log"
  LOCK_FILE="${LOG_FILE}.lock"

  # Creator: touch lock ДО запуска analyzer (spec §4.3.1 Lock contract)
  touch "$LOCK_FILE" 2>/dev/null

  case "$analyzer" in
    phpstan)
      CMD=("$PROJECT_DIR/vendor/bin/phpstan" "analyse" "--no-progress" "--error-format=raw" "$FILE")
      ;;
    go-vet)
      # go vet работает на пакете, не на файле — берём dirname
      CMD=("go" "vet" "$(dirname "$FILE")")
      ;;
    staticcheck)
      CMD=("staticcheck" "$(dirname "$FILE")")
      ;;
    tsc)
      # tsc --noEmit на проекте (per-file invocation тяжелый, project-level фастый и full)
      if [[ -x "$PROJECT_DIR/node_modules/.bin/tsc" ]]; then
        CMD=("$PROJECT_DIR/node_modules/.bin/tsc" "--noEmit")
      else
        CMD=("tsc" "--noEmit")
      fi
      ;;
    eslint)
      if [[ -x "$PROJECT_DIR/node_modules/.bin/eslint" ]]; then
        CMD=("$PROJECT_DIR/node_modules/.bin/eslint" "--no-color" "--format=compact" "$FILE")
      else
        CMD=("eslint" "--no-color" "--format=compact" "$FILE")
      fi
      ;;
  esac

  # Subshell с trap чтобы lock cleanup'нулся при kill (spec §4.3.1 Cleaner happy/stale)
  # nohup + & — detach от parent, tool result не ждёт
  (
    trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT INT TERM
    cd "$PROJECT_DIR" 2>/dev/null
    {
      echo "[static-prepass] analyzer=$analyzer file=$FILE pid=$$"
      echo "[static-prepass] cmd: ${CMD[*]}"
      echo "[static-prepass] start: $(date -Iseconds 2>/dev/null || date)"
      echo "---"
      $TIMEOUT_CMD "${CMD[@]}" 2>&1
      EC=$?
      echo "---"
      echo "[static-prepass] exit_code=$EC end: $(date -Iseconds 2>/dev/null || date)"
    } > "$LOG_FILE" 2>&1
    rm -f "$LOCK_FILE" 2>/dev/null
  ) &
  disown 2>/dev/null || true
done

exit 0
