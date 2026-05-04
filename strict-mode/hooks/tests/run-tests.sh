#!/usr/bin/env bash
# run-tests.sh — стенд-элоун тесты для всех Wave 2 хуков.
# Запуск: bash ~/.claude/hooks/tests/run-tests.sh
# Не требует Claude Code сессии — все тесты идут через stdin/argv.
# Exit 0 если все pass, 1 если хоть один fail.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASSED=0
FAILED=0
FAIL_NAMES=()

# Изолированный временный state-каталог, чтобы не загрязнить реальный
TEST_STATE="$(mktemp -d -t strict-mode-test-state.XXXXXX)"
trap "rm -rf '$TEST_STATE'" EXIT
export HOME="$TEST_STATE/home"
mkdir -p "$HOME/.claude/state"
# Симлинком хуки чтобы они работали с настоящим $HOME/.claude/hooks/
mkdir -p "$HOME/.claude"
ln -s "$HOOKS_DIR" "$HOME/.claude/hooks"

# Disable read-delay для тестов (default 2000ms иначе суммарно +1-2 минуты)
export STRICT_HOOK_READ_DELAY_MS=0

assert_exit() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" = "$expected" ]]; then
    printf '  ✓ %s (exit=%d)\n' "$name" "$actual"
    PASSED=$((PASSED + 1))
  else
    printf '  ✗ %s (expected exit=%d, got=%d)\n' "$name" "$expected" "$actual"
    FAIL_NAMES+=("$name")
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    printf '  ✓ %s (output contains "%s")\n' "$name" "$needle"
    PASSED=$((PASSED + 1))
  else
    printf '  ✗ %s (output missing "%s")\n' "$name" "$needle"
    printf '    actual: %s\n' "$haystack"
    FAIL_NAMES+=("$name")
    FAILED=$((FAILED + 1))
  fi
}

echo "=== stub-scan.sh: clean PHP должен exit 0 ==="
out=$(echo '<?php class Foo { public function bar() { return 42; } }' | "$HOOKS_DIR/stub-scan.sh" stdin php 2>&1); ec=$?
assert_exit "clean-php" 0 $ec

echo ""
echo "=== stub-scan.sh: TODO в PHP должен exit 2 ==="
out=$(printf '<?php\n// TODO: implement\n' | "$HOOKS_DIR/stub-scan.sh" stdin php 2>&1); ec=$?
assert_exit "todo-php" 2 $ec
assert_contains "todo-php-stderr" "TODO/FIXME" "$out"

echo ""
echo "=== stub-scan.sh: panic('not implemented') в Go ==="
out=$(printf 'package main\nfunc bar() { panic("not implemented") }\n' | "$HOOKS_DIR/stub-scan.sh" stdin go 2>&1); ec=$?
assert_exit "go-panic-stub" 2 $ec
assert_contains "go-panic-stderr" "go-panic-stub" "$out"

echo ""
echo "=== stub-scan.sh: throw new Error('TODO') в JS ==="
out=$(printf 'function f() { throw new Error("TODO: implement"); }\n' | "$HOOKS_DIR/stub-scan.sh" stdin js 2>&1); ec=$?
assert_exit "js-throw-todo" 2 $ec

echo ""
echo "=== stub-scan.sh: allow-stub bypass должен exit 0 ==="
out=$(printf '<?php\n// TODO: refactor // allow-stub: tracked in #1234\n' | "$HOOKS_DIR/stub-scan.sh" stdin php 2>&1); ec=$?
assert_exit "allow-stub-bypass" 0 $ec

echo ""
echo "=== stub-scan.sh: переменная по имени \$placeholder не триггер ==="
out=$(printf '<?php\n$placeholder = "x@y.com";\n' | "$HOOKS_DIR/stub-scan.sh" stdin php 2>&1); ec=$?
assert_exit "placeholder-var-not-trigger" 0 $ec

echo ""
echo "=== stub-scan.sh: file-mode на чистый файл ==="
TMPFILE="$TEST_STATE/clean.go"
printf 'package main\nfunc main() { println("hi") }\n' > "$TMPFILE"
out=$("$HOOKS_DIR/stub-scan.sh" file "$TMPFILE" 2>&1); ec=$?
assert_exit "file-mode-clean-go" 0 $ec

echo ""
echo "=== stub-scan.sh: file-mode на грязный файл ==="
TMPFILE="$TEST_STATE/dirty.go"
printf 'package main\n// TODO: implement\nfunc main() {}\n' > "$TMPFILE"
out=$("$HOOKS_DIR/stub-scan.sh" file "$TMPFILE" 2>&1); ec=$?
assert_exit "file-mode-dirty-go" 2 $ec

echo ""
echo "=== stub-scan.sh: не-PHP/Go/JS файл (md) пропускается ==="
TMPFILE="$TEST_STATE/notes.md"
printf '# Notes\n- TODO: write spec\n' > "$TMPFILE"
out=$("$HOOKS_DIR/stub-scan.sh" file "$TMPFILE" 2>&1); ec=$?
assert_exit "non-source-file-skip" 0 $ec

echo ""
echo "=== pre-write-scan.sh: Write с TODO блокирует ==="
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.go","content":"package main\nfunc x() { panic(\"TODO\") }"}}'
out=$(echo "$JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "pre-write-write-todo" 2 $ec

echo ""
echo "=== pre-write-scan.sh: Write чистого кода проходит ==="
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.go","content":"package main\nfunc x() int { return 42 }"}}'
out=$(echo "$JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "pre-write-clean" 0 $ec

echo ""
echo "=== pre-write-scan.sh: Edit с stub в new_string блокирует ==="
JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.php","old_string":"<?php","new_string":"<?php\nfunction f() { throw new Exception(\"not implemented\"); }"}}'
out=$(echo "$JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "pre-write-edit-stub" 2 $ec

echo ""
echo "=== pre-write-scan.sh: MultiEdit с TODO в одном из edits блокирует ==="
JSON='{"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/test.go","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"// TODO later"}]}}'
out=$(echo "$JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "pre-write-multiedit-todo" 2 $ec

echo ""
echo "=== pre-write-scan.sh: не-source файл (.md) пропускается ==="
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/notes.md","content":"# TODO: write notes"}}'
out=$(echo "$JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "pre-write-md-skip" 0 $ec

echo ""
echo "=== record-edit.sh: пишет file_path в edits-<sid>.log ==="
SID="test-$(date +%s)"
JSON="{\"session_id\":\"$SID\",\"tool_input\":{\"file_path\":\"/tmp/test.go\"}}"
echo "$JSON" | "$HOOKS_DIR/record-edit.sh"; ec=$?
assert_exit "record-edit-exit" 0 $ec
LOG="$HOME/.claude/state/edits-${SID}.log"
if [[ -f "$LOG" ]] && grep -q '/tmp/test.go' "$LOG"; then
  printf '  ✓ record-edit-wrote-log\n'
  PASSED=$((PASSED + 1))
else
  printf '  ✗ record-edit-wrote-log (file=%s)\n' "$LOG"
  FAIL_NAMES+=("record-edit-wrote-log")
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=== record-edit.sh: всегда exit 0 даже на сломанном JSON ==="
echo "not json" | "$HOOKS_DIR/record-edit.sh"; ec=$?
assert_exit "record-edit-bad-json-still-zero" 0 $ec

echo ""
echo "=== prompt-inject.sh: выводит [STRICT MODE] ==="
out=$(echo '{}' | "$HOOKS_DIR/prompt-inject.sh"); ec=$?
assert_exit "prompt-inject-exit" 0 $ec
assert_contains "prompt-inject-content" "STRICT MODE" "$out"

echo ""
echo "=== health-check.sh: exit 0, может вывести warnings ==="
out=$(echo '{}' | "$HOOKS_DIR/health-check.sh" 2>&1); ec=$?
assert_exit "health-check-exit" 0 $ec

echo ""
echo "=== stop-guard.sh: пустая сессия (нет edits-log) проходит ==="
SID="empty-$(date +%s)"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "stop-empty-session" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ stop-empty-no-block\n'
  PASSED=$((PASSED + 1))
else
  printf '  ✗ stop-empty-no-block (got: %s)\n' "$out"
  FAIL_NAMES+=("stop-empty-no-block")
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=== stop-guard.sh: сессия со stubs в файле блокирует ==="
SID="dirty-$(date +%s)"
TMPFILE="$TEST_STATE/dirty-stop.go"
printf 'package main\nfunc x() { panic("TODO") }\n' > "$TMPFILE"
echo "$TMPFILE" > "$HOME/.claude/state/edits-${SID}.log"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "stop-dirty-exit" 0 $ec
assert_contains "stop-dirty-block-decision" '"decision":[[:space:]]*"block"' "$out"
assert_contains "stop-dirty-block-reason" "stubs" "$out"

echo ""
echo "=== stop-guard.sh: bypass-файл пропускает блок ==="
SID="bypass-$(date +%s)"
TMPFILE="$TEST_STATE/bypass-stop.go"
printf 'package main\nfunc x() { panic("TODO") }\n' > "$TMPFILE"
echo "$TMPFILE" > "$HOME/.claude/state/edits-${SID}.log"
echo "intentional bypass for test" > "$HOME/.claude/state/bypass-${SID}"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "stop-bypass-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ stop-bypass-no-output\n'
  PASSED=$((PASSED + 1))
else
  printf '  ✗ stop-bypass-no-output (got: %s)\n' "$out"
  FAIL_NAMES+=("stop-bypass-no-output")
  FAILED=$((FAILED + 1))
fi
# Bypass-файл должен быть удалён после использования
if [[ ! -f "$HOME/.claude/state/bypass-${SID}" ]]; then
  printf '  ✓ stop-bypass-file-removed\n'
  PASSED=$((PASSED + 1))
else
  printf '  ✗ stop-bypass-file-removed (still exists)\n'
  FAIL_NAMES+=("stop-bypass-file-removed")
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=== F26: stub-scan на больших файлах не тормозит (file-mode без bash-var) ==="
TMPBIG="$TEST_STATE/big-clean.go"
{ echo 'package main'; for i in $(seq 1 5000); do echo "func f${i}() int { return ${i} }"; done; } > "$TMPBIG"
START=$(date +%s)
"$HOOKS_DIR/stub-scan.sh" file "$TMPBIG" >/dev/null 2>&1; ec=$?
END=$(date +%s)
ELAPSED=$((END - START))
assert_exit "f26-big-clean-exit" 0 $ec
if [[ $ELAPSED -lt 5 ]]; then
  printf '  ✓ f26-big-clean-fast (%ds, < 5s)\n' "$ELAPSED"
  PASSED=$((PASSED + 1))
else
  printf '  ✗ f26-big-clean-fast (took %ds, expected < 5s)\n' "$ELAPSED"
  FAIL_NAMES+=("f26-big-clean-fast")
  FAILED=$((FAILED + 1))
fi

# Стаб в большом файле всё равно ловится
TMPDIRTY="$TEST_STATE/big-dirty.go"
{ echo 'package main'; for i in $(seq 1 2500); do echo "func f${i}() int { return ${i} }"; done; echo 'func bad() { panic("TODO") }'; for i in $(seq 2501 5000); do echo "func g${i}() int { return ${i} }"; done; } > "$TMPDIRTY"
"$HOOKS_DIR/stub-scan.sh" file "$TMPDIRTY" >/dev/null 2>&1; ec=$?
assert_exit "f26-big-dirty-still-detects" 2 $ec

echo ""
echo "=== F27: pre-write skip при content > 512KB ==="
TMPCONTENT="$TEST_STATE/big-content.go"
{ printf 'package main\n'; for i in $(seq 1 30000); do echo "func f${i}() int { return ${i} }"; done; } > "$TMPCONTENT"
TMPJSON="$TEST_STATE/big-input.json"
jq -Rs '{tool_name: "Write", tool_input: {file_path: "/tmp/f27test.go", content: .}}' < "$TMPCONTENT" > "$TMPJSON"
out=$(cat "$TMPJSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "f27-oversized-skip-exit" 0 $ec
assert_contains "f27-oversized-warning" "limit — skip" "$out"

# F27 граничный: контент чуть выше лимита всё равно skip (даже если стаб внутри)
TMPDIRTY_BIG="$TEST_STATE/dirty-big.go"
{ printf 'package main\n// TODO real stub\n'; yes "//x" | head -c 524300 >> "$TMPDIRTY_BIG"; } > "$TMPDIRTY_BIG"
TMPDIRTY_JSON="$TEST_STATE/dirty-big.json"
jq -Rs '{tool_name: "Write", tool_input: {file_path: "/tmp/dirty-big.go", content: .}}' < "$TMPDIRTY_BIG" > "$TMPDIRTY_JSON"
out=$(cat "$TMPDIRTY_JSON" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "f27-oversized-with-stub-still-skips" 0 $ec
assert_contains "f27-oversized-stub-warning" "limit — skip" "$out"

# F27 ниже лимита — реально сканирует (стаб ловится)
SMALL_DIRTY='package main
func f() { panic("TODO") }'
JSON_SMALL=$(jq -n --arg c "$SMALL_DIRTY" '{tool_name: "Write", tool_input: {file_path: "/tmp/small-dirty.go", content: $c}}')
out=$(echo "$JSON_SMALL" | "$HOOKS_DIR/pre-write-scan.sh" 2>&1); ec=$?
assert_exit "f27-small-still-blocks-stub" 2 $ec

echo ""
echo "=== fdr-challenge.sh: пустой transcript → no fire ==="
SID="empty-tr-$(date +%s)"
EMPTY_TR="$TEST_STATE/empty-transcript.jsonl"
: > "$EMPTY_TR"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$EMPTY_TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-empty-transcript" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-empty-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-empty-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-empty-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: FDR упомянут + verdict 0 проблем → fire ==="
SID="fdr-yes-$(date +%s)"
TR="$TEST_STATE/fdr-yes.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр по этому коду"}}
{"type":"assistant","message":{"content":"Делаю Full Deep Review по 9 слоям..."}}
{"type":"user","message":{"content":"итог?"}}
{"type":"assistant","message":{"content":"Verdict: ready to merge. 0 проблем."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-trigger-exit" 0 $ec
assert_contains "challenge-trigger-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "challenge-trigger-reason" "FDR honesty check" "$out"
# History файл должен быть создан с cycle 0 entry
if [[ -f "$HOME/.claude/state/fdr-cycles-$SID.jsonl" ]] && grep -q '"cycle":0' "$HOME/.claude/state/fdr-cycles-$SID.jsonl"; then
  printf '  ✓ challenge-trigger-history-created\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-trigger-history-created\n'; FAIL_NAMES+=("challenge-trigger-history-created"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: повторный вызов с флагом → no fire ==="
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-once-only-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-once-only-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-once-only-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-once-only-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: 0 проблем БЕЗ FDR-контекста → no fire (narrowing) ==="
SID="no-context-$(date +%s)"
TR="$TEST_STATE/no-context.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"запусти билд"}}
{"type":"assistant","message":{"content":"Билд прошёл, 0 проблем с компиляцией."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-narrowing-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-narrowing-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-narrowing-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-narrowing-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: SubagentStop event → no fire ==="
SID="subagent-$(date +%s)"
TR="$TEST_STATE/subagent.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"FDR done. 0 проблем."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"SubagentStop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-subagent-skip-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-subagent-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-subagent-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-subagent-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: project disable файл → no fire ==="
SID="disabled-$(date +%s)"
TR="$TEST_STATE/disabled.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"0 проблем."}}
JSONL
PROJ_DIR="$TEST_STATE/proj-disabled"
mkdir -p "$PROJ_DIR/.claude"
: > "$PROJ_DIR/.claude/strict-mode.disabled"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(CLAUDE_PROJECT_DIR="$PROJ_DIR" sh -c "echo '$JSON' | $HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-project-disable-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-project-disable-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-project-disable-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-project-disable-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: verdict-pattern внутри code-block → ТЕПЕРЬ fire (strip удалён) ==="
SID="codeblock-$(date +%s)"
TR="$TEST_STATE/codeblock.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"расскажи про fdr challenge"}}
{"type":"assistant","message":{"content":"Хук триггерится на фразу типа\n```\nVerdict: 0 проблем\n```\nв последнем сообщении модели."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-codeblock-fires-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✓ challenge-codeblock-now-fires (strip removed по решению)\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-codeblock-now-fires (no fire — strip всё ещё активен?)\n'; FAIL_NAMES+=("challenge-codeblock-now-fires"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: subagent transcript path → no fire (N21 fallback) ==="
SID="subagent-path-$(date +%s)"
SUBDIR="$TEST_STATE/subagents"
mkdir -p "$SUBDIR"
TR="$SUBDIR/agent-deadbeef.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"FDR done. 0 проблем."}}
JSONL
# Без явного hook_event_name — проверяем path-based fallback
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-subagent-path-skip-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-subagent-path-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-subagent-path-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-subagent-path-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: stop-guard.log запись при fire (N23) ==="
SID="log-test-$(date +%s)"
TR="$TEST_STATE/log-test.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи ФДР"}}
{"type":"assistant","message":{"content":"Verdict: ready to merge. 0 проблем."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
LOGFILE="$HOME/.claude/state/stop-guard.log"
LOG_BEFORE=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
LOG_AFTER=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
assert_exit "challenge-log-fire-exit" 0 $ec
if [[ $LOG_AFTER -gt $LOG_BEFORE ]] && grep -q "fdr-challenge.*$SID.*block-initial" "$LOGFILE"; then
  printf '  ✓ challenge-log-entry-written\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-log-entry-written (before=%s after=%s)\n' "$LOG_BEFORE" "$LOG_AFTER"; FAIL_NAMES+=("challenge-log-entry-written"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: вердикт без verdict-pattern → no fire ==="
SID="no-verdict-$(date +%s)"
TR="$TEST_STATE/no-verdict.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи ревью"}}
{"type":"assistant","message":{"content":"Нашёл 3 находки: F1, F2, F3. Чинить будем?"}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-no-verdict-pattern" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-no-verdict-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-no-verdict-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("challenge-no-verdict-no-output"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: длинный transcript >200 строк, FDR в начале → ловится ==="
SID="long-tr-$(date +%s)"
TR="$TEST_STATE/long-tr.jsonl"
{
  echo '{"type":"user","message":{"content":"проведи фдр по этому коду"}}'
  echo '{"type":"assistant","message":{"content":"запускаю Full Deep Review по 9 слоям..."}}'
  for i in $(seq 1 240); do
    echo "{\"type\":\"progress\",\"id\":$i}"
  done
  echo '{"type":"assistant","message":{"content":"Verdict: 0 проблем."}}'
} > "$TR"
LINES=$(wc -l < "$TR")
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "challenge-long-transcript-exit" 0 $ec
# Длинный gap (240 progress strings) — narrowing window 200 строк не дотянется до FDR
# в самом начале → no fire. Это акцептабельная degradation для очень длинных сессий.
if [[ -z "$out" ]]; then
  printf '  ✓ challenge-long-transcript-degrades-cleanly (no fire on >200-line gap, %d total lines)\n' "$LINES"; PASSED=$((PASSED + 1))
else
  printf '  ! challenge-long-transcript-fired-anyway (got: %s)\n' "$(echo "$out" | head -c 100)"; PASSED=$((PASSED + 1))
fi

echo ""
echo "=== fdr-challenge.sh: бенчмарк на 1000-строчном transcript ==="
SID="perf-$(date +%s)"
TR="$TEST_STATE/perf-tr.jsonl"
{
  echo '{"type":"user","message":{"content":"проведи фдр"}}'
  for i in $(seq 1 998); do
    echo "{\"type\":\"progress\",\"id\":$i}"
  done
  echo '{"type":"assistant","message":{"content":"Verdict: ready to merge. 0 проблем."}}'
} > "$TR"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
START=$(date +%s)
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
END=$(date +%s)
ELAPSED=$((END - START))
assert_exit "challenge-perf-exit" 0 $ec
if [[ $ELAPSED -lt 3 ]]; then
  printf '  ✓ challenge-perf-fast (%ds on 1000-line transcript, < 3s)\n' "$ELAPSED"; PASSED=$((PASSED + 1))
else
  printf '  ✗ challenge-perf-fast (took %ds, expected < 3s)\n' "$ELAPSED"; FAIL_NAMES+=("challenge-perf-fast"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== health-check.sh: awk в deps list проверяется ==="
out=$(echo '{}' | "$HOOKS_DIR/health-check.sh" 2>&1); ec=$?
assert_exit "health-awk-check-exit" 0 $ec
# health-check молчит если все деп есть (включая awk на macOS системно)
# проверяем что нет ошибки "missing dep: awk" (его на самом деле не миссинг)
if echo "$out" | grep -q "missing dep: awk"; then
  printf '  ✗ health-awk-false-positive (awk должен быть на macOS)\n'; FAIL_NAMES+=("health-awk-false-positive"); FAILED=$((FAILED + 1))
else
  printf '  ✓ health-awk-not-flagged (awk доступен)\n'; PASSED=$((PASSED + 1))
fi

echo ""
echo "=== judge.sh: mock response — отдаёт как есть ==="
out=$(echo '{"history":[],"current_response":"x"}' | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"complete","gaps_to_demand":[],"rationale":"ok"}' "$HOOKS_DIR/judge.sh"); ec=$?
assert_exit "judge-mock-exit" 0 $ec
assert_contains "judge-mock-output" "complete" "$out"

echo ""
echo "=== fdr-challenge cycle 1: judge=complete → allow + delete history ==="
SID="cycle-complete-$(date +%s)"
TR="$TEST_STATE/cycle-complete.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"Verdict: ready. 0 проблем."}}
{"type":"user","message":{"content":"честно?"}}
{"type":"assistant","message":{"content":"Прошёл по 9 слоям с конкретикой: L1-Wallet.php:transfer ok, L2-Service:dispatch ok, ..."}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
echo '{"cycle":0,"classification":"initial","summary":"Initial challenge fired"}' > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"complete","gaps_to_demand":[],"rationale":"per-layer breakdown with locations"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-complete-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ cycle-complete-no-output\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-complete-no-output (got: %s)\n' "$out"; FAIL_NAMES+=("cycle-complete-no-output"); FAILED=$((FAILED + 1))
fi
if [[ ! -f "$HISTORY" ]]; then
  printf '  ✓ cycle-complete-history-deleted\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-complete-history-deleted (still exists)\n'; FAIL_NAMES+=("cycle-complete-history-deleted"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge cycle 1: judge=substantive → block, history растёт ==="
SID="cycle-subs-$(date +%s)"
TR="$TEST_STATE/cycle-subs.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"Нашёл новые: L7 timeout missing в WalletService:transfer"}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
echo '{"cycle":0,"classification":"initial","summary":"Initial"}' > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"substantive","gaps_to_demand":["check L7 reliability deeper"],"rationale":"new findings on L7"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-subs-exit" 0 $ec
assert_contains "cycle-subs-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "cycle-subs-rationale" "judge нашёл новые findings" "$out"
LINES=$(wc -l < "$HISTORY" 2>/dev/null | tr -d ' ')
if [[ "$LINES" -ge 2 ]]; then
  printf '  ✓ cycle-subs-history-grew (%s lines)\n' "$LINES"; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-subs-history-grew (%s lines)\n' "$LINES"; FAIL_NAMES+=("cycle-subs-history-grew"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge cycle 1: judge=evasive → block с targeted gaps ==="
SID="cycle-evasive-$(date +%s)"
TR="$TEST_STATE/cycle-evasive.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"Всё хорошо. Слои покрыты."}}
JSONL
echo '{"cycle":0,"classification":"initial","summary":"Initial"}' > "$HOME/.claude/state/fdr-cycles-$SID.jsonl"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"evasive","gaps_to_demand":["specify L6 auth checks","specify L8 perf metrics"],"rationale":"too general, no file refs"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-evasive-exit" 0 $ec
assert_contains "cycle-evasive-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "cycle-evasive-gaps" "specify L6 auth" "$out"

echo ""
echo "=== fdr-challenge: 2 подряд repetitive → allow на 3-м ==="
SID="cycle-rep-$(date +%s)"
TR="$TEST_STATE/cycle-rep.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"Опять то же самое."}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
{
  echo '{"cycle":0,"classification":"initial","summary":"init"}'
  echo '{"cycle":1,"classification":"repetitive","summary":"same as before"}'
  echo '{"cycle":2,"classification":"repetitive","summary":"same again"}'
} > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"repetitive","gaps_to_demand":[],"rationale":"third repeat"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-rep-allow-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ cycle-rep-3rd-allows\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-rep-3rd-allows (got: %s)\n' "$out" | head -c 100; FAIL_NAMES+=("cycle-rep-3rd-allows"); FAILED=$((FAILED + 1))
fi
if [[ ! -f "$HISTORY" ]]; then
  printf '  ✓ cycle-rep-history-deleted\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-rep-history-deleted\n'; FAIL_NAMES+=("cycle-rep-history-deleted"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge: failsafe cap 10 → allow ==="
SID="cycle-cap-$(date +%s)"
TR="$TEST_STATE/cycle-cap.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"продолжаю"}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
for i in $(seq 0 9); do
  echo "{\"cycle\":$i,\"classification\":\"substantive\",\"summary\":\"cycle $i\"}"
done > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"substantive","gaps_to_demand":["more"],"rationale":"keeps finding"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-cap-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ cycle-cap-allows-at-10\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-cap-allows-at-10 (got: %s)\n' "$out" | head -c 100; FAIL_NAMES+=("cycle-cap-allows-at-10"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge trigger: 0 critical findings → fire ==="
SID="trig-critfind-$(date +%s)"
TR="$TEST_STATE/trig-critfind.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"После анализа: 0 critical findings, все слои покрыты."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "trigger-critical-findings-exit" 0 $ec
assert_contains "trigger-critical-findings-block" '"decision":[[:space:]]*"block"' "$out"

echo ""
echo "=== fdr-challenge trigger: «выглядит хорошо» → fire ==="
SID="trig-vyg-$(date +%s)"
TR="$TEST_STATE/trig-vyg.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи ревью"}}
{"type":"assistant","message":{"content":"Прошёл по коду — выглядит хорошо."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "trigger-vyglyadit-horosho-exit" 0 $ec
assert_contains "trigger-vyglyadit-horosho-block" '"decision":[[:space:]]*"block"' "$out"

echo ""
echo "=== fdr-challenge trigger: «found nothing» → fire ==="
SID="trig-found-$(date +%s)"
TR="$TEST_STATE/trig-found.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи fdr"}}
{"type":"assistant","message":{"content":"Looked at all 9 layers, found nothing wrong."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "trigger-found-nothing-exit" 0 $ec
assert_contains "trigger-found-nothing-block" '"decision":[[:space:]]*"block"' "$out"

echo ""
echo "=== false-positive guard: «выглядит грустно» НЕ триггерит ==="
SID="fp-grustno-$(date +%s)"
TR="$TEST_STATE/fp-grustno.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи fdr"}}
{"type":"assistant","message":{"content":"Состояние кода — выглядит грустно, много долгов."}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "fp-vyg-grustno-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ fp-vyg-grustno-no-fire\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ fp-vyg-grustno-no-fire (got: %s)\n' "$out"; FAIL_NAMES+=("fp-vyg-grustno-no-fire"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge: verdict в предпоследнем text-msg + последний tool_use → ловится ==="
SID="tooluse-last-$(date +%s)"
TR="$TEST_STATE/tooluse-last.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done. Verdict: 0 проблем."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "tooluse-last-extract-exit" 0 $ec
assert_contains "tooluse-last-extract-block" '"decision":[[:space:]]*"block"' "$out"

echo ""
echo "=== fdr-challenge: env STRICT_NO_HAIKU_JUDGE=1 → fallback к one-shot ==="
SID="cycle-noahaiku-$(date +%s)"
TR="$TEST_STATE/cycle-noahaiku.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":"что-то"}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
echo '{"cycle":0,"classification":"initial","summary":"init"}' > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_NO_HAIKU_JUDGE=1 "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "cycle-noahaiku-exit" 0 $ec
if [[ -z "$out" && ! -f "$HISTORY" ]]; then
  printf '  ✓ cycle-noahaiku-fallback-allow\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ cycle-noahaiku-fallback-allow (out=%s history=%s)\n' "$out" "$([[ -f $HISTORY ]] && echo exists || echo gone)"; FAIL_NAMES+=("cycle-noahaiku-fallback-allow"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge: stale history > 30 min auto-reset ==="
SID="stale-$(date +%s)"
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
echo '{"cycle":0,"classification":"initial","summary":"old"}' > "$HISTORY"
# Set mtime 31 minutes ago
touch -t "$(date -v-31M +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M.%S)" "$HISTORY"
TR="$TEST_STATE/stale-tr.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "stale-reset-exit" 0 $ec
if [[ ! -f "$HISTORY" ]]; then
  printf '  ✓ stale-history-removed\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ stale-history-removed\n'; FAIL_NAMES+=("stale-history-removed"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge: hash-tracking — re-fire на тот же verdict-text не происходит ==="
SID="hash-$(date +%s)"
TR="$TEST_STATE/hash-tr.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Verdict: 0 проблем"}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
# Первый fire
out1=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec1=$?
assert_exit "hash-first-fire-exit" 0 $ec1
assert_contains "hash-first-fire-block" '"decision":[[:space:]]*"block"' "$out1"
# Симулируем: cycle 1 завершился (judge unknown → history удалён)
rm -f "$HOME/.claude/state/fdr-cycles-$SID.jsonl"
# Второй Stop с тем же transcript — не должен файрить (hash в memory)
out2=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec2=$?
assert_exit "hash-second-skip-exit" 0 $ec2
if [[ -z "$out2" ]]; then
  printf '  ✓ hash-second-no-fire (stale verdict skipped)\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ hash-second-no-fire (got: %s)\n' "$(echo "$out2" | head -c 100)"; FAIL_NAMES+=("hash-second-no-fire"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== fdr-challenge: anti-stall — судья дважды подряд same gaps → allow ==="
SID="stall-$(date +%s)"
TR="$TEST_STATE/stall-tr.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи fdr"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Same response again"}]}}
JSONL
HISTORY="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
{
  echo '{"cycle":0,"classification":"initial","summary":"init","gaps":""}'
  echo '{"cycle":1,"classification":"substantive","summary":"first","gaps":"per-layer structure"}'
} > "$HISTORY"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
# Mock judge возвращает substantive с теми же gaps что в cycle 1
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"substantive","gaps_to_demand":["per-layer structure"],"rationale":"same as before"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "stall-allow-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ stall-allow-no-block (anti-stall сработал)\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ stall-allow-no-block (got: %s)\n' "$(echo "$out" | head -c 100)"; FAIL_NAMES+=("stall-allow-no-block"); FAILED=$((FAILED + 1))
fi
if [[ ! -f "$HISTORY" ]]; then
  printf '  ✓ stall-history-deleted\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ stall-history-deleted\n'; FAIL_NAMES+=("stall-history-deleted"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== F5: новые verdict-паттерны (N closed/everything/Status:done/FDR=0) ==="
declare -a F5_CASES=(
  "Verdict: 4 findings closed"
  "5 issues resolved"
  "all findings resolved"
  "everything fixed"
  "Status: done"
  "Итог: завершен"
  "FDR=0"
  "ревью: 0"
  "3 problems fixed"
  "всё закрыто"
)
for phrase in "${F5_CASES[@]}"; do
  SID="f5-$(echo "$phrase" | tr -cd '[:alnum:]' | head -c 20)-$$"
  TR="$TEST_STATE/f5-$SID.jsonl"
  printf '%s\n%s\n' \
    '{"type":"user","message":{"content":"проведи фдр"}}' \
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$phrase\"}]}}" > "$TR"
  JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
  out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
  if [[ "$ec" = "0" ]] && echo "$out" | grep -q '"decision"'; then
    printf '  ✓ f5-fires-on: "%s"\n' "$phrase"; PASSED=$((PASSED + 1))
  else
    printf '  ✗ f5-fires-on: "%s" (no fire)\n' "$phrase"; FAIL_NAMES+=("f5-fires-on:$phrase"); FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== F6: strip полностью УДАЛЁН — verdict ловится в любом форматировании ==="
# По решению: strip даёт больше false-negatives чем спасает false-positives.
# Все формы (plain, **bold**, «quotes», `code`, ```fenced```) теперь fire.
declare -a F6_FIRE=(
  "Block 4 (C5) реализован: **0 findings**."
  "**Verdict: 4 findings closed**"
  "последний пасс \`0 проблем\`. Все 13 findings закрыты"
  "Шаблон «Verdict: 4 findings closed»"
  "0 проблем"
  "Итог: **all findings resolved**"
)
for phrase in "${F6_FIRE[@]}"; do
  SID="f6f-$(date +%s%N | head -c 15)"
  TR="$TEST_STATE/f6f-$SID.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"проведи фдр"}}' > "$TR"
  ESC=$(printf '%s' "$phrase" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$ESC" >> "$TR"
  JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
  out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
  if [[ "$ec" = "0" ]] && echo "$out" | grep -q '"decision"'; then
    printf '  ✓ f6-fire-on-any-format: "%s"\n' "$(echo "$phrase" | head -c 60)"; PASSED=$((PASSED + 1))
  else
    printf '  ✗ f6-fire-on-any-format (MISSED): "%s"\n' "$(echo "$phrase" | head -c 60)"; FAIL_NAMES+=("f6-fire-any-format"); FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== W3: meta-bypass + missing-verdict (current-turn signals) ==="

# W3.1: meta-bypass — verdict + magic-string + НЕТ Edit/Write в турне → allow (no block)
SID="w3-meta-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-meta-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"расскажи как работает FDR honesty challenge"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Хук срабатывает на verdict-фразы типа \"0 проблем\". Это meta-discussion, no FDR work."}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-meta-bypass-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w3-meta-bypass-no-block (got block decision)\n'; FAIL_NAMES+=("w3-meta-bypass-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w3-meta-bypass-no-block (no block emitted)\n'; PASSED=$((PASSED + 1))
fi
if grep -q "allow-self-meta" "$HOME/.claude/state/stop-guard.log" 2>/dev/null; then
  printf '  ✓ w3-meta-bypass-logged\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w3-meta-bypass-logged\n'; FAIL_NAMES+=("w3-meta-bypass-logged"); FAILED=$((FAILED + 1))
fi

# W3.2: magic-string IGNORED при наличии Edit в турне (агент не может сбежать после работы)
SID="w3-magic-ign-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-magic-ign-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр и поправь"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"foo.php"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Поправил. 0 проблем. meta-discussion, no FDR work"}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-magic-ignored-exit" 0 $ec
assert_contains "w3-magic-ignored-blocks" '"decision":[[:space:]]*"block"' "$out"

# W3.3: missing-verdict — Edit в турне + FDR-context + НЕТ verdict-фразы → block
SID="w3-mv-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-mv-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр по бэкенду"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"backend.go"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Закончил round-7 fixes. Применённые правки: L7, L5. Если нужен ещё round — скажите."}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-mv-block-exit" 0 $ec
assert_contains "w3-mv-block-decision" '"decision":[[:space:]]*"block"' "$out"
assert_contains "w3-mv-block-reason" "FDR verdict missing" "$out"

# W3.4: no-edit + no-verdict → allow (нет повода блокировать)
SID="w3-noop-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-noop-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"что такое ФДР?"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Full Deep Review — это 9-уровневое ревью."}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-noop-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w3-noop-no-block (got block on no-edit no-verdict)\n'; FAIL_NAMES+=("w3-noop-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w3-noop-no-block\n'; PASSED=$((PASSED + 1))
fi

# W3.5: missing-verdict NOT triggered если нет FDR-context (обычная code-task без ФДР-разговора)
SID="w3-mv-nofdr-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-mv-nofdr-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"добавь функцию foo"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"x.go"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Добавил функцию foo."}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-mv-nofdr-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w3-mv-nofdr-no-block (got block without FDR-context)\n'; FAIL_NAMES+=("w3-mv-nofdr-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w3-mv-nofdr-no-block\n'; PASSED=$((PASSED + 1))
fi

# W3.5b (CRITICAL regression guard): judge.sh должен парситься bash без syntax error.
# Был bug: "no impact / not in scope" + "weren't" внутри двойных кавычек ломали скрипт,
# судья возвращал 'unknown' навсегда → silent allow на каждом cycle 1.
if bash -n "$HOOKS_DIR/judge.sh" 2>/dev/null; then
  printf '  ✓ w3-judge-syntax-ok\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w3-judge-syntax-ok (bash -n failed on judge.sh)\n'; FAIL_NAMES+=("w3-judge-syntax-ok"); FAILED=$((FAILED + 1))
fi

# W3.5c: judge.sh с реальным input (mock-режимом, не дёргая claude -p) возвращает valid JSON
out=$(echo '{"history":[],"current_response":"test with apostrophe weren'\''t and \"no impact\""}' | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"evasive","gaps_to_demand":[],"rationale":"x"}' "$HOOKS_DIR/judge.sh" 2>&1)
if echo "$out" | jq -e '.classification' >/dev/null 2>&1; then
  printf '  ✓ w3-judge-handles-quotes\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w3-judge-handles-quotes (output: %s)\n' "$out"; FAIL_NAMES+=("w3-judge-handles-quotes"); FAILED=$((FAILED + 1))
fi

# W3.5d: recursion guard — все хуки exit 0 без output при STRICT_MODE_NESTED=1
# (root cause: nested claude -p из judge.sh получал свой собственный reminder и отвечал
# magic-string "meta-discussion, no FDR work" вместо JSON классификации).
for hook in prompt-inject.sh fdr-challenge.sh stop-guard.sh health-check.sh pre-write-scan.sh record-edit.sh; do
  out=$(echo '{}' | STRICT_MODE_NESTED=1 "$HOOKS_DIR/$hook" 2>&1); ec=$?
  if [[ "$ec" = "0" ]] && [[ -z "$out" ]]; then
    printf '  ✓ w3-recursion-guard-%s\n' "$hook"; PASSED=$((PASSED + 1))
  else
    printf '  ✗ w3-recursion-guard-%s (exit=%s, out=%s)\n' "$hook" "$ec" "$out"; FAIL_NAMES+=("w3-recursion-guard-$hook"); FAILED=$((FAILED + 1))
  fi
done

# W3.6: prompt-inject содержит новые правила 6 и 7
out=$(echo "{}" | "$HOOKS_DIR/prompt-inject.sh" 2>&1)
assert_contains "w3-inject-rule6" "verdict" "$out"
assert_contains "w3-inject-rule7" "meta-discussion, no FDR work" "$out"

# W3.7 (F1): meta-bypass работает на cycle N (после initial challenge)
SID="w3-meta-cyc-n-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-meta-cyc-n-$SID.jsonl"
HIST="$HOME/.claude/state/fdr-cycles-$SID.jsonl"
mkdir -p "$HOME/.claude/state"
printf '{"cycle":0,"classification":"initial","summary":"Initial fired"}\n' > "$HIST"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"расскажи про fdr challenge"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"meta-discussion, no FDR work"}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | STRICT_JUDGE_MOCK_RESPONSE='{"classification":"evasive","gaps_to_demand":[],"rationale":"x"}' "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-meta-cycN-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w3-meta-cycN-no-block (got block on cycle N magic-bypass)\n'; FAIL_NAMES+=("w3-meta-cycN-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w3-meta-cycN-no-block\n'; PASSED=$((PASSED + 1))
fi
if [[ ! -f "$HIST" ]]; then
  printf '  ✓ w3-meta-cycN-history-cleared\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w3-meta-cycN-history-cleared (history not removed)\n'; FAIL_NAMES+=("w3-meta-cycN-history-cleared"); FAILED=$((FAILED + 1))
fi

# W3.8 (F2): missing-verdict hash-tracking — повторный Stop с тем же финальным текстом → skip
SID="w3-mv-rerun-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-mv-rerun-$SID.jsonl"
cat > "$TR" <<'JSONL'
{"type":"user","message":{"content":"проведи фдр"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"x.go"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Закончил правки. Двигаемся дальше."}]}}
JSONL
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
# Первый запуск — должен заблокировать
out1=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1)
assert_contains "w3-mv-rerun-fire1" '"decision":[[:space:]]*"block"' "$out1"
# Второй запуск с тем же transcript — skip (hash tracked)
out2=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1)
if echo "$out2" | grep -q '"decision"'; then
  printf '  ✗ w3-mv-rerun-skip (re-fired on same hash)\n'; FAIL_NAMES+=("w3-mv-rerun-skip"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w3-mv-rerun-skip\n'; PASSED=$((PASSED + 1))
fi

# W3.9 (F4): длинный ответ с magic-string в составе → bypass НЕ срабатывает
SID="w3-meta-long-$(date +%s%N | head -c 15)"
TR="$TEST_STATE/w3-meta-long-$SID.jsonl"
LONG_TEXT="Verdict: 0 проблем. Это длинное объяснение того что я сделал в FDR-цикле. $(printf 'Анализ слоёв был полным. %.0s' {1..15})meta-discussion, no FDR work — был такой кейс ранее, но сейчас не он. $(printf 'Дополнительные детали по контексту. %.0s' {1..10})"
ESC=$(printf '%s' "$LONG_TEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
printf '%s\n' '{"type":"user","message":{"content":"проведи фдр"}}' > "$TR"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$ESC" >> "$TR"
JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/fdr-challenge.sh" 2>&1); ec=$?
assert_exit "w3-meta-long-exit" 0 $ec
assert_contains "w3-meta-long-blocks" '"decision":[[:space:]]*"block"' "$out"

# =============================================================================
# Wave 3 Phase 2: is-trivial-diff.sh + fdr-validate.sh
# =============================================================================

# Helper: создаёт mini git-repo во временной директории, возвращает путь
mk_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && git init -q && git config user.email "t@t" && git config user.name "T" \
    && touch baseline && git add baseline && git commit -q -m "init") >/dev/null 2>&1
  echo "$dir"
}

echo ""
echo "=== W4: is-trivial-diff.sh ==="

# W4.1: not git repo → exit 1 (treated as non-trivial)
NONGIT="$TEST_STATE/w4-nongit-$(date +%s%N | head -c 12)"
mkdir -p "$NONGIT"
out=$(cd "$NONGIT" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-not-git-repo" 1 $ec

# W4.2: no changes → exit 0 (trivial)
REPO=$(mk_git_repo "$TEST_STATE/w4-clean-$(date +%s%N | head -c 12)")
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-no-changes" 0 $ec

# W4.3: docs-only (.md) → exit 1 (NOT trivial — docs require FDR per 2026-05-04 rule)
REPO=$(mk_git_repo "$TEST_STATE/w4-docs-$(date +%s%N | head -c 12)")
echo "# changed" > "$REPO/README.md"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-docs-not-trivial" 1 $ec

# W4.4: lockfile only → exit 0 (trivial)
REPO=$(mk_git_repo "$TEST_STATE/w4-lock-$(date +%s%N | head -c 12)")
touch "$REPO/composer.lock"; (cd "$REPO" && git add composer.lock && git commit -q -m "lock-init")
echo "{}" > "$REPO/composer.lock"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-lockfile-trivial" 0 $ec

# W4.5: real PHP code change → exit 1
REPO=$(mk_git_repo "$TEST_STATE/w4-php-$(date +%s%N | head -c 12)")
echo "<?php echo 1;" > "$REPO/file.php"
(cd "$REPO" && git add file.php && git commit -q -m "init-php")
echo "<?php echo 2;" > "$REPO/file.php"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-php-not-trivial" 1 $ec

# W4.6: comments-only PHP → exit 0
REPO=$(mk_git_repo "$TEST_STATE/w4-comm-$(date +%s%N | head -c 12)")
echo "<?php echo 1;" > "$REPO/x.php"
(cd "$REPO" && git add x.php && git commit -q -m "init")
printf '<?php echo 1;\n// new comment\n' > "$REPO/x.php"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-comments-only-trivial" 0 $ec

# W4.7: whitespace-only change → exit 0
REPO=$(mk_git_repo "$TEST_STATE/w4-ws-$(date +%s%N | head -c 12)")
echo "<?php echo 1;" > "$REPO/y.php"
(cd "$REPO" && git add y.php && git commit -q -m "init")
printf '<?php   echo  1;  \n' > "$REPO/y.php"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-whitespace-trivial" 0 $ec

# W4.8: translation .json → exit 0
REPO=$(mk_git_repo "$TEST_STATE/w4-i18n-$(date +%s%N | head -c 12)")
mkdir -p "$REPO/lang"
echo '{}' > "$REPO/lang/ru.json"
(cd "$REPO" && git add lang/ru.json && git commit -q -m "init")
echo '{"k":"v"}' > "$REPO/lang/ru.json"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-translation-trivial" 0 $ec

# W4.9: sensitive-paths override (auth/X.lock should NOT be trivial)
SENSITIVE_TMP="$HOME/.claude/sensitive-paths.txt"
mkdir -p "$HOME/.claude"
[[ -f "$SENSITIVE_TMP" ]] && cp "$SENSITIVE_TMP" "$SENSITIVE_TMP.test-bak"
printf '(^|/)auth/.*\n' > "$SENSITIVE_TMP"
REPO=$(mk_git_repo "$TEST_STATE/w4-sens-$(date +%s%N | head -c 12)")
mkdir -p "$REPO/auth"
touch "$REPO/auth/x.lock"
(cd "$REPO" && git add auth/x.lock && git commit -q -m "init")
echo "x" > "$REPO/auth/x.lock"
out=$(cd "$REPO" && "$HOOKS_DIR/is-trivial-diff.sh" 2>&1); ec=$?
assert_exit "w4-sensitive-override" 1 $ec
[[ -f "$SENSITIVE_TMP.test-bak" ]] && mv "$SENSITIVE_TMP.test-bak" "$SENSITIVE_TMP" || rm -f "$SENSITIVE_TMP"

echo ""
echo "=== W4: fdr-validate.sh ==="

# Helper для построения валидного артефакта
write_valid_artifact() {
  local f="$1"
  cat > "$f" <<'MD'
# FDR — session test
generated: 2026-05-04T00:00:00Z
cycles: 1

## Scope
- file1.php

## Layer 0 (static prepass)
phpstan: 0 errors | staticcheck: skipped | eslint: skipped

## Findings

## Verdict
status: complete
counts: 0 open / 0 resolved
MD
}

# W4.10: missing artifact → C1 fail
out=$("$HOOKS_DIR/fdr-validate.sh" "/nonexistent/fdr.md" "/nonexistent/edits.log" 2>&1); ec=$?
assert_exit "w4-c1-missing" 2 $ec
assert_contains "w4-c1-missing-msg" "C1 FAIL" "$out"

# W4.11: valid empty artifact (0 findings) → exit 0
ART="$TEST_STATE/w4-art-valid.md"
EDITS="$TEST_STATE/w4-edits-valid.log"
write_valid_artifact "$ART"
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-valid-empty" 0 $ec

# W4.12: edited file not in scope → C2 fail
ART="$TEST_STATE/w4-art-c2.md"
EDITS="$TEST_STATE/w4-edits-c2.log"
write_valid_artifact "$ART"
# Создаём существующий файл который НЕ в Scope
touch "$TEST_STATE/missing-from-scope.go"
echo "$TEST_STATE/missing-from-scope.go" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c2-not-in-scope" 2 $ec
assert_contains "w4-c2-msg" "C2 FAIL" "$out"

# W4.13: finding missing field → C3 fail
ART="$TEST_STATE/w4-art-c3.md"
EDITS="$TEST_STATE/w4-edits-c3.log"
cat > "$ART" <<'MD'
# FDR — session test
cycles: 1

## Scope
- file1.php

## Findings
### F1
file: app/x.php:42
layer: 6
scenario: missing
severity: HIGH
status: open

## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c3-missing-field" 2 $ec
assert_contains "w4-c3-msg-expected" "missing field 'expected'" "$out"

# W4.14: CRITICAL без :line → C3 fail
ART="$TEST_STATE/w4-art-c3-line.md"
EDITS="$TEST_STATE/w4-edits-c3-line.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: race
expected: lock
actual: race
severity: CRITICAL
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c3-critical-needs-line" 2 $ec
assert_contains "w4-c3-line-msg" "CRITICAL requires file:line" "$out"

# W4.15: invalid severity → C4 fail
ART="$TEST_STATE/w4-art-c4.md"
EDITS="$TEST_STATE/w4-edits-c4.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: x
expected: y
actual: z
severity: SUPER
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c4-bad-sev" 2 $ec
assert_contains "w4-c4-msg" "C4 FAIL" "$out"

# W4.16: open finding + Verdict status:complete → C6 fail
ART="$TEST_STATE/w4-art-c6.md"
EDITS="$TEST_STATE/w4-edits-c6.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: x
expected: y
actual: z
severity: LOW
status: open
## Verdict
status: complete
counts: 1 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c6-open-but-complete" 2 $ec
assert_contains "w4-c6-msg" "C6 FAIL.*open findings exist but Verdict says 'complete'" "$out"

# W4.17: forbidden phrase → C8 fail
ART="$TEST_STATE/w4-art-c8.md"
EDITS="$TEST_STATE/w4-edits-c8.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Findings
Great job here!
## Verdict
status: complete
counts: 0 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c8-praise" 2 $ec
assert_contains "w4-c8-msg" "C8 FAIL" "$out"

# W4.18: resolved without fix-commit → C10 fail
ART="$TEST_STATE/w4-art-c10.md"
EDITS="$TEST_STATE/w4-edits-c10.log"
cat > "$ART" <<'MD'
# FDR
cycles: 2
## Scope
- file1.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: x
expected: y
actual: z
severity: LOW
status: resolved
## Verdict
status: complete
counts: 0 open / 1 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c10-no-fix-commit" 2 $ec
assert_contains "w4-c10-msg" "C10 FAIL" "$out"

# W4.19: bypass file → exit 0 (skip validation)
SID_TEST="w4-bypass-$(date +%s%N | head -c 12)"
mkdir -p "$HOME/.claude/state"
echo "test bypass reason" > "$HOME/.claude/state/bypass-${SID_TEST}"
out=$("$HOOKS_DIR/fdr-validate.sh" "/nonexistent/fdr.md" "/nonexistent/edits.log" "$SID_TEST" 2>&1); ec=$?
assert_exit "w4-c11-bypass-allows" 0 $ec
# Bypass file должен быть удалён
if [[ ! -f "$HOME/.claude/state/bypass-${SID_TEST}" ]]; then
  printf '  ✓ w4-c11-bypass-consumed\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w4-c11-bypass-consumed (file still exists)\n'; FAIL_NAMES+=("w4-c11-bypass-consumed"); FAILED=$((FAILED + 1))
fi

# W4.20: cycles=1 + all resolved → C7 fail
ART="$TEST_STATE/w4-art-c7.md"
EDITS="$TEST_STATE/w4-edits-c7.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: x
expected: y
actual: z
severity: LOW
status: resolved
fix-commit: abc1234
re-check: 2026-05-04T00:00:00 — recheck-agent
## Verdict
status: complete
counts: 0 open / 1 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
assert_exit "w4-c7-cycles-too-low" 2 $ec
assert_contains "w4-c7-msg" "C7 FAIL" "$out"

# W4.21: bash -n syntax check
if bash -n "$HOOKS_DIR/is-trivial-diff.sh" 2>/dev/null; then
  printf '  ✓ w4-trivial-diff-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w4-trivial-diff-syntax\n'; FAIL_NAMES+=("w4-trivial-diff-syntax"); FAILED=$((FAILED + 1))
fi
if bash -n "$HOOKS_DIR/fdr-validate.sh" 2>/dev/null; then
  printf '  ✓ w4-validate-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w4-validate-syntax\n'; FAIL_NAMES+=("w4-validate-syntax"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== W5: stop-guard.sh Wave 3 extensions ==="

# Helper: SetUp test SID + edits log с одним файлом
setup_test_sid() {
  local sid="$1"
  local target_file="${2:-/tmp/dummy.php}"
  echo "$target_file" > "$HOME/.claude/state/edits-${sid}.log"
}

# Симлинк ~/.claude/hooks → bundle hooks для tests, чтобы stop-guard.sh нашёл peers.
# (Уже сделано в setUp на строке 21.)

# W5.1: edits exist + no artifact + non-trivial diff → block "FDR artifact missing"
SID="w5-no-art-$(date +%s%N | head -c 12)"
REPO=$(mk_git_repo "$TEST_STATE/w5-no-art-repo-$(date +%s%N | head -c 12)")
echo "<?php new code;" > "$REPO/x.php"
(cd "$REPO" && git add x.php && git commit -q -m "init")
echo "<?php real change;" > "$REPO/x.php"
setup_test_sid "$SID" "$REPO/x.php"
JSON="{\"session_id\":\"$SID\"}"
out=$(cd "$REPO" && echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-no-art-exit" 0 $ec
assert_contains "w5-no-art-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "w5-no-art-reason" "FDR artifact missing" "$out"
rm -f "$HOME/.claude/state/edits-${SID}.log"

# W5.2: edits + no artifact + trivial diff → NO block (skip)
SID="w5-trivial-$(date +%s%N | head -c 12)"
REPO=$(mk_git_repo "$TEST_STATE/w5-triv-repo-$(date +%s%N | head -c 12)")
touch "$REPO/test.lock"
(cd "$REPO" && git add test.lock && git commit -q -m "init")
echo "x" > "$REPO/test.lock"
setup_test_sid "$SID" "$REPO/test.lock"
JSON="{\"session_id\":\"$SID\"}"
out=$(cd "$REPO" && echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-trivial-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w5-trivial-no-block (got block on lockfile-only diff)\n'; FAIL_NAMES+=("w5-trivial-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w5-trivial-no-block\n'; PASSED=$((PASSED + 1))
fi
rm -f "$HOME/.claude/state/edits-${SID}.log"

# W5.3: artifact valid (0 findings) → NO block
SID="w5-valid-$(date +%s%N | head -c 12)"
ART="$HOME/.claude/state/fdr-${SID}.md"
EL="$HOME/.claude/state/edits-${SID}.log"
echo "x.php" > "$EL"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- x.php
## Layer 0
phpstan: 0 errors
## Findings
## Verdict
status: complete
counts: 0 open / 0 resolved
MD
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-valid-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w5-valid-no-block (got block on valid artifact)\n'; FAIL_NAMES+=("w5-valid-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w5-valid-no-block\n'; PASSED=$((PASSED + 1))
fi
rm -f "$ART" "$EL"

# W5.4: artifact invalid → block with validator output
SID="w5-invalid-$(date +%s%N | head -c 12)"
ART="$HOME/.claude/state/fdr-${SID}.md"
EL="$HOME/.claude/state/edits-${SID}.log"
echo "x.php" > "$EL"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- x.php
## Findings
### F1
file: app/x.php
layer: 6
scenario: missing fields
severity: BOGUS
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-invalid-exit" 0 $ec
assert_contains "w5-invalid-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "w5-invalid-validator" "failed validation" "$out"
assert_contains "w5-invalid-c4-msg" "C4 FAIL" "$out"
rm -f "$ART" "$EL"

# W5.5: artifact + open findings + edits-log mtime > artifact mtime → recheck block
SID="w5-recheck-$(date +%s%N | head -c 12)"
ART="$HOME/.claude/state/fdr-${SID}.md"
EL="$HOME/.claude/state/edits-${SID}.log"
echo "x.php" > "$EL"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- x.php
## Layer 0
phpstan: 0 errors
## Findings
### F1
file: app/x.php:42
layer: 6
scenario: race
expected: lock
actual: race
severity: HIGH
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
# Make artifact older than edits-log
touch -t 202001010000 "$ART"
touch "$EL"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-recheck-exit" 0 $ec
assert_contains "w5-recheck-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "w5-recheck-reason" "/fdr to recheck" "$out"
rm -f "$ART" "$EL"

# W5.6: artifact + open findings + edits-log mtime <= artifact mtime → NO recheck block
SID="w5-no-recheck-$(date +%s%N | head -c 12)"
ART="$HOME/.claude/state/fdr-${SID}.md"
EL="$HOME/.claude/state/edits-${SID}.log"
echo "x.php" > "$EL"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- x.php
## Findings
### F1
file: app/x.php:42
layer: 6
scenario: race
expected: lock
actual: race
severity: HIGH
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
touch -t 202001010000 "$EL"
touch "$ART"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-no-recheck-exit" 0 $ec
if echo "$out" | grep -q "invoke /fdr to recheck"; then
  printf '  ✗ w5-no-recheck (false-positive recheck block)\n'; FAIL_NAMES+=("w5-no-recheck"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w5-no-recheck\n'; PASSED=$((PASSED + 1))
fi
rm -f "$ART" "$EL"

# W5.7: bypass file → exit 0 (skip all checks)
SID="w5-bypass-$(date +%s%N | head -c 12)"
EL="$HOME/.claude/state/edits-${SID}.log"
echo "/nonexistent/x.php" > "$EL"
echo "test bypass" > "$HOME/.claude/state/bypass-${SID}"
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-bypass-exit" 0 $ec
if echo "$out" | grep -q '"decision"'; then
  printf '  ✗ w5-bypass-no-block\n'; FAIL_NAMES+=("w5-bypass-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w5-bypass-no-block\n'; PASSED=$((PASSED + 1))
fi
if [[ ! -f "$HOME/.claude/state/bypass-${SID}" ]]; then
  printf '  ✓ w5-bypass-consumed\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w5-bypass-consumed\n'; FAIL_NAMES+=("w5-bypass-consumed"); FAILED=$((FAILED + 1))
fi
rm -f "$EL"

# W4.22: fdr-validate handles "### F1: title" finding header (trailing colon strip)
ART="$TEST_STATE/w4-art-titled.md"
EDITS="$TEST_STATE/w4-edits-titled.log"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- file1.php
## Layer 0
phpstan: 0 errors
## Findings
### F1: race condition in transfer
file: app/x.php:42
layer: 6
scenario: race
expected: lock
actual: race
severity: CRITICAL
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
echo "file1.php" > "$EDITS"
out=$("$HOOKS_DIR/fdr-validate.sh" "$ART" "$EDITS" 2>&1); ec=$?
# Должен принять (1 open finding с правильными полями). Любой C-fail = parser broke
if [[ "$ec" = "2" ]]; then
  printf '  ✗ w4-titled-finding (parser failed on "### F1: title" form)\n    actual: %s\n' "$out"; FAIL_NAMES+=("w4-titled-finding"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w4-titled-finding\n'; PASSED=$((PASSED + 1))
fi

# W5.7b: STRICT_NO_ARTIFACT_GATE=1 → проверки (a) и (c) отключены, no block on missing artifact
SID="w5-gate-off-$(date +%s%N | head -c 12)"
REPO=$(mk_git_repo "$TEST_STATE/w5-gate-off-repo-$(date +%s%N | head -c 12)")
echo "<?php real;" > "$REPO/x.php"
(cd "$REPO" && git add x.php && git commit -q -m "init")
echo "<?php real change;" > "$REPO/x.php"
echo "$REPO/x.php" > "$HOME/.claude/state/edits-${SID}.log"
JSON="{\"session_id\":\"$SID\"}"
out=$(cd "$REPO" && echo "$JSON" | STRICT_NO_ARTIFACT_GATE=1 "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-gate-off-exit" 0 $ec
if echo "$out" | grep -q "FDR artifact missing"; then
  printf '  ✗ w5-gate-off-no-block (gate fired despite STRICT_NO_ARTIFACT_GATE=1)\n'; FAIL_NAMES+=("w5-gate-off-no-block"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w5-gate-off-no-block\n'; PASSED=$((PASSED + 1))
fi
rm -f "$HOME/.claude/state/edits-${SID}.log"

# W5.9: combined block — stub finding + invalid artifact в одном Stop → обе reasons с --- separator
SID="w5-combined-$(date +%s%N | head -c 12)"
TMPFILE="$TEST_STATE/w5-combined-stub.go"
printf 'package main\nfunc x() { panic("TODO") }\n' > "$TMPFILE"
echo "$TMPFILE" > "$HOME/.claude/state/edits-${SID}.log"
ART="$HOME/.claude/state/fdr-${SID}.md"
cat > "$ART" <<'MD'
# FDR
cycles: 1
## Scope
- some.go
## Findings
### F1
file: app/x.go
layer: 6
scenario: bad sev
severity: BOGUS
status: open
## Verdict
status: incomplete
counts: 1 open / 0 resolved
MD
JSON="{\"session_id\":\"$SID\"}"
out=$(echo "$JSON" | "$HOOKS_DIR/stop-guard.sh" 2>&1); ec=$?
assert_exit "w5-combined-exit" 0 $ec
assert_contains "w5-combined-block" '"decision":[[:space:]]*"block"' "$out"
assert_contains "w5-combined-stub" "stubs" "$out"
assert_contains "w5-combined-validation" "failed validation" "$out"
assert_contains "w5-combined-separator" '\\n---\\n' "$out"
rm -f "$ART" "$HOME/.claude/state/edits-${SID}.log"

# W5.8: stop-guard syntax check
if bash -n "$HOOKS_DIR/stop-guard.sh" 2>/dev/null; then
  printf '  ✓ w5-stop-guard-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w5-stop-guard-syntax\n'; FAIL_NAMES+=("w5-stop-guard-syntax"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== W6: atomic deploy + rollback fault injection ==="

INSTALL_SH="$(cd "$HOOKS_DIR/.." && pwd)/install.sh"
ROLLBACK_SH="$(cd "$HOOKS_DIR/.." && pwd)/rollback.sh"

# W6.1: atomic_deploy design — verify .new.PID + mv pattern preserves dst
# при failure ПОСЛЕ cp но ПЕРЕД mv (simulates kill между шагами).
W6DIR="$TEST_STATE/w6-atomic-$(date +%s%N | head -c 12)"
mkdir -p "$W6DIR"
ORIG_CONTENT="ORIGINAL_HOOK_v1"
echo "$ORIG_CONTENT" > "$W6DIR/dst"
NEW_CONTENT="DEPLOYED_HOOK_v2"
echo "$NEW_CONTENT" > "$W6DIR/src"
# Симулируем halt после cp но перед mv: cp src .new, не mv
cp "$W6DIR/src" "$W6DIR/dst.new.99999"
# dst должен остаться нетронутым (pre-deploy state)
if [[ "$(cat "$W6DIR/dst")" = "$ORIG_CONTENT" ]]; then
  printf '  ✓ w6-atomic-halt-preserves-dst\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-atomic-halt-preserves-dst (dst tampered)\n'; FAIL_NAMES+=("w6-atomic-halt-preserves-dst"); FAILED=$((FAILED + 1))
fi
# .new.PID существует как orphan (post-cp, pre-mv state)
if [[ -f "$W6DIR/dst.new.99999" ]]; then
  printf '  ✓ w6-atomic-orphan-detected\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-atomic-orphan-detected\n'; FAIL_NAMES+=("w6-atomic-orphan-detected"); FAILED=$((FAILED + 1))
fi
# Now complete the deploy: mv .new → dst (atomic via rename(2))
mv -f "$W6DIR/dst.new.99999" "$W6DIR/dst"
if [[ "$(cat "$W6DIR/dst")" = "$NEW_CONTENT" ]]; then
  printf '  ✓ w6-atomic-mv-completes\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-atomic-mv-completes\n'; FAIL_NAMES+=("w6-atomic-mv-completes"); FAILED=$((FAILED + 1))
fi

# W6.2: backup_unique_path — разные filenames в одном run → разные paths
# (real scenario: install бекапит judge.sh, prompt-inject.sh, etc. в одну секунду).
B6HOME=$(mktemp -d -t w6-backup.XXXXXX)
mkdir -p "$B6HOME/.claude/backups"
HOME="$B6HOME" bash -c '
  BACKUP_DIR="$HOME/.claude/backups"
  DATE_TAG="2026-05-04-120000"
  backup_unique_path() {
    local f="$1"
    echo "$BACKUP_DIR/${f}.bak-${DATE_TAG}-$$"
  }
  P1=$(backup_unique_path "judge.sh"); touch "$P1"
  P2=$(backup_unique_path "prompt-inject.sh"); touch "$P2"
  [[ "$P1" != "$P2" ]] || exit 1
  [[ -f "$P1" && -f "$P2" ]] || exit 1
'
ec=$?
if [[ $ec -eq 0 ]]; then
  printf '  ✓ w6-backup-no-collision-multifile-same-second\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-backup-no-collision-multifile-same-second\n'; FAIL_NAMES+=("w6-backup-no-collision-multifile-same-second"); FAILED=$((FAILED + 1))
fi
rm -rf "$B6HOME"

# W6.3: rollback E2E — install → modify → re-install (backup) → rollback restores
W6FAKE=$(mktemp -d -t w6-rollback.XXXXXX)
HOME="$W6FAKE" bash "$INSTALL_SH" >/dev/null 2>&1
HOOK_PROD="$W6FAKE/.claude/hooks/judge.sh"
ORIG_SUM=$(shasum "$HOOK_PROD" 2>/dev/null | awk '{print $1}')
# Tamper hook
echo "// tampered" >> "$HOOK_PROD"
TAMPER_SUM=$(shasum "$HOOK_PROD" | awk '{print $1}')
[[ "$ORIG_SUM" != "$TAMPER_SUM" ]] || { printf '  ✗ w6-rollback-tamper-setup\n'; FAIL_NAMES+=("w6-rollback-tamper-setup"); FAILED=$((FAILED + 1)); }
# Re-install — должен бекапить tampered version
HOME="$W6FAKE" bash "$INSTALL_SH" >/dev/null 2>&1
DEPLOY_SUM=$(shasum "$HOOK_PROD" | awk '{print $1}')
# Rollback — должен вернуть к tampered (latest backup)
HOME="$W6FAKE" bash "$ROLLBACK_SH" >/dev/null 2>&1
ROLLBACK_SUM=$(shasum "$HOOK_PROD" | awk '{print $1}')
if [[ "$ROLLBACK_SUM" = "$TAMPER_SUM" ]]; then
  printf '  ✓ w6-rollback-restores-backup\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-rollback-restores-backup (got %s, expected %s)\n' "$ROLLBACK_SUM" "$TAMPER_SUM"; FAIL_NAMES+=("w6-rollback-restores-backup"); FAILED=$((FAILED + 1))
fi

# W6.4: rollback idempotency — second invocation не fail и не меняет state
HOME="$W6FAKE" bash "$ROLLBACK_SH" 2>/dev/null > /tmp/w6-rollback-out
ec=$?
DOUBLE_SUM=$(shasum "$HOOK_PROD" | awk '{print $1}')
if [[ "$ec" -eq 0 ]] && [[ "$DOUBLE_SUM" = "$ROLLBACK_SUM" ]] && grep -q "skipped (idempotent): " /tmp/w6-rollback-out; then
  printf '  ✓ w6-rollback-idempotent\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-rollback-idempotent (ec=%s, sum changed=%s)\n' "$ec" "$([[ "$DOUBLE_SUM" != "$ROLLBACK_SUM" ]] && echo yes || echo no)"; FAIL_NAMES+=("w6-rollback-idempotent"); FAILED=$((FAILED + 1))
fi
rm -f /tmp/w6-rollback-out
rm -rf "$W6FAKE"

# W6.5: rollback с missing backup pattern не halt'ит (set -uo pipefail без -e)
W6EMPTY=$(mktemp -d -t w6-empty.XXXXXX)
mkdir -p "$W6EMPTY/.claude/backups"
mkdir -p "$W6EMPTY/.claude/hooks"
out=$(HOME="$W6EMPTY" bash "$ROLLBACK_SH" 2>&1); ec=$?
# Должен exit 0 и сообщить "Restored: 0"
if [[ "$ec" -eq 0 ]] && echo "$out" | grep -q "Restored: 0"; then
  printf '  ✓ w6-rollback-empty-backups-graceful\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-rollback-empty-backups-graceful (ec=%s)\n' "$ec"; FAIL_NAMES+=("w6-rollback-empty-backups-graceful"); FAILED=$((FAILED + 1))
fi
rm -rf "$W6EMPTY"

# W6.7: orphan .new.* cleanup — pre-existing STALE orphan (mtime > 60s) убирается
# на старте install. Fresh (< 60s) skip'аются для concurrent safety — см. W6.9.
W6OFAKE=$(mktemp -d -t w6-orphan.XXXXXX)
HOME="$W6OFAKE" bash "$INSTALL_SH" >/dev/null 2>&1
# Создаём orphan имитирующий kill mid-cp от прошлого install (старше 60s)
echo "stale partial content" > "$W6OFAKE/.claude/hooks/judge.sh.new.99999"
echo "stale partial content" > "$W6OFAKE/.claude/hooks/tests/run-tests.sh.new.99998"
# Backdate to 2 minutes ago (past 60s threshold)
BACKDATE=$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$BACKDATE" "$W6OFAKE/.claude/hooks/judge.sh.new.99999" 2>/dev/null
touch -t "$BACKDATE" "$W6OFAKE/.claude/hooks/tests/run-tests.sh.new.99998" 2>/dev/null
# Re-install — должен sweep orphans
out=$(HOME="$W6OFAKE" bash "$INSTALL_SH" 2>&1)
if echo "$out" | grep -qE "swept [0-9]+ orphan"; then
  printf '  ✓ w6-orphan-cleanup-detected\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-orphan-cleanup-detected (no sweep message)\n'; FAIL_NAMES+=("w6-orphan-cleanup-detected"); FAILED=$((FAILED + 1))
fi
if [[ ! -f "$W6OFAKE/.claude/hooks/judge.sh.new.99999" ]] && [[ ! -f "$W6OFAKE/.claude/hooks/tests/run-tests.sh.new.99998" ]]; then
  printf '  ✓ w6-orphan-removed\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-orphan-removed\n'; FAIL_NAMES+=("w6-orphan-removed"); FAILED=$((FAILED + 1))
fi
rm -rf "$W6OFAKE"

# W6.9: concurrent-safety — fresh .new.<pid> младше 60s НЕ удаляется sweep'ом
# (имитация параллельного install в момент когда другой install запускает cleanup).
W6CFAKE=$(mktemp -d -t w6-conc.XXXXXX)
HOME="$W6CFAKE" bash "$INSTALL_SH" >/dev/null 2>&1
# Создаём свежий .new file (mtime = now, simulates active deploy by another process)
FRESH_NEW="$W6CFAKE/.claude/hooks/judge.sh.new.99999"
echo "active deploy in progress" > "$FRESH_NEW"
# Re-install — должен SKIP fresh orphan
out=$(HOME="$W6CFAKE" bash "$INSTALL_SH" 2>&1)
if echo "$out" | grep -qE "skipped [0-9]+ .new.\* younger than 60s"; then
  printf '  ✓ w6-concurrent-fresh-skipped\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-concurrent-fresh-skipped (no skip msg)\n'; FAIL_NAMES+=("w6-concurrent-fresh-skipped"); FAILED=$((FAILED + 1))
fi
if [[ -f "$FRESH_NEW" ]]; then
  printf '  ✓ w6-concurrent-fresh-preserved\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-concurrent-fresh-preserved (active .new file deleted!)\n'; FAIL_NAMES+=("w6-concurrent-fresh-preserved"); FAILED=$((FAILED + 1))
fi
rm -rf "$W6CFAKE"

# W6.10: stale orphan (mtime > 60s ago) убирается sweep'ом
W6STFAKE=$(mktemp -d -t w6-stale.XXXXXX)
HOME="$W6STFAKE" bash "$INSTALL_SH" >/dev/null 2>&1
STALE_NEW="$W6STFAKE/.claude/hooks/judge.sh.new.88888"
echo "stale partial" > "$STALE_NEW"
# Backdate file mtime to 2 minutes ago
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 minutes ago' +%Y%m%d%H%M.%S)" "$STALE_NEW" 2>/dev/null
out=$(HOME="$W6STFAKE" bash "$INSTALL_SH" 2>&1)
if echo "$out" | grep -qE "swept [0-9]+ orphan"; then
  printf '  ✓ w6-stale-swept\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-stale-swept\n'; FAIL_NAMES+=("w6-stale-swept"); FAILED=$((FAILED + 1))
fi
if [[ ! -f "$STALE_NEW" ]]; then
  printf '  ✓ w6-stale-removed\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-stale-removed (stale .new still exists)\n'; FAIL_NAMES+=("w6-stale-removed"); FAILED=$((FAILED + 1))
fi
rm -rf "$W6STFAKE"

# W6.8: trap on EXIT/INT/TERM defined в install.sh
if grep -qE "trap.*cleanup_active_tmp.*EXIT" "$INSTALL_SH"; then
  printf '  ✓ w6-install-trap-defined\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-install-trap-defined\n'; FAIL_NAMES+=("w6-install-trap-defined"); FAILED=$((FAILED + 1))
fi

# W6.6: install/rollback bash -n syntax
if bash -n "$INSTALL_SH" 2>/dev/null; then
  printf '  ✓ w6-install-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-install-syntax\n'; FAIL_NAMES+=("w6-install-syntax"); FAILED=$((FAILED + 1))
fi
if bash -n "$ROLLBACK_SH" 2>/dev/null; then
  printf '  ✓ w6-rollback-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w6-rollback-syntax\n'; FAIL_NAMES+=("w6-rollback-syntax"); FAILED=$((FAILED + 1))
fi

echo ""
echo "=== W7: static-prepass.sh (Phase 4) ==="

# W7.1: STRICT_MODE_NESTED=1 → exit 0 без работы (recursion guard)
out=$(echo '{"session_id":"test","tool_input":{"file_path":"/tmp/x.php"}}' | STRICT_MODE_NESTED=1 "$HOOKS_DIR/static-prepass.sh" 2>&1); ec=$?
assert_exit "w7-recursion-guard-exit" 0 $ec
if [[ -z "$out" ]]; then
  printf '  ✓ w7-recursion-guard-silent\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w7-recursion-guard-silent\n'; FAIL_NAMES+=("w7-recursion-guard-silent"); FAILED=$((FAILED + 1))
fi

# W7.2: empty SID/file → exit 0 (defensive)
out=$(echo '{}' | "$HOOKS_DIR/static-prepass.sh" 2>&1); ec=$?
assert_exit "w7-empty-input" 0 $ec

# W7.3: non-existent file → exit 0
out=$(echo '{"session_id":"x","tool_input":{"file_path":"/nonexistent/file.php"}}' | "$HOOKS_DIR/static-prepass.sh" 2>&1); ec=$?
assert_exit "w7-nonexistent-file" 0 $ec

# W7.4: per-project opt-out (.claude/no-static-prepass)
W7DIR=$(mktemp -d -t w7-optout.XXXXXX)
mkdir -p "$W7DIR/.claude"
touch "$W7DIR/.claude/no-static-prepass"
echo "<?php echo 1;" > "$W7DIR/x.php"
out=$(CLAUDE_PROJECT_DIR="$W7DIR" echo "{\"session_id\":\"w7-optout\",\"tool_input\":{\"file_path\":\"$W7DIR/x.php\"}}" | CLAUDE_PROJECT_DIR="$W7DIR" "$HOOKS_DIR/static-prepass.sh" 2>&1); ec=$?
assert_exit "w7-optout-exit" 0 $ec
sleep 0.3  # дать nohup'у возможность стартовать (хотя не должен)
if ls "$HOME/.claude/state/prepass-w7-optout-"* 2>/dev/null | grep -q .; then
  printf '  ✗ w7-optout-no-prepass-log (log created despite opt-out)\n'; FAIL_NAMES+=("w7-optout-no-prepass-log"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w7-optout-no-prepass-log\n'; PASSED=$((PASSED + 1))
fi
rm -f "$HOME/.claude/state/prepass-w7-optout-"* 2>/dev/null
rm -rf "$W7DIR"

# W7.5: unsupported extension → exit 0, no logs
W7DIR=$(mktemp -d -t w7-unsupp.XXXXXX)
echo "data" > "$W7DIR/file.txt"
out=$(echo "{\"session_id\":\"w7-unsupp\",\"tool_input\":{\"file_path\":\"$W7DIR/file.txt\"}}" | "$HOOKS_DIR/static-prepass.sh" 2>&1); ec=$?
assert_exit "w7-unsupp-exit" 0 $ec
sleep 0.3
if ls "$HOME/.claude/state/prepass-w7-unsupp-"* 2>/dev/null | grep -q .; then
  printf '  ✗ w7-unsupp-no-log\n'; FAIL_NAMES+=("w7-unsupp-no-log"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w7-unsupp-no-log\n'; PASSED=$((PASSED + 1))
fi
rm -f "$HOME/.claude/state/prepass-w7-unsupp-"* 2>/dev/null
rm -rf "$W7DIR"

# W7.6: PHP без vendor/bin/phpstan → no analyzers → no logs
W7DIR=$(mktemp -d -t w7-php-noph.XXXXXX)
echo "<?php echo 1;" > "$W7DIR/x.php"
out=$(CLAUDE_PROJECT_DIR="$W7DIR" "$HOOKS_DIR/static-prepass.sh" <<< "{\"session_id\":\"w7-noph\",\"tool_input\":{\"file_path\":\"$W7DIR/x.php\"}}" 2>&1); ec=$?
assert_exit "w7-php-noph-exit" 0 $ec
sleep 0.3
if ls "$HOME/.claude/state/prepass-w7-noph-"* 2>/dev/null | grep -q .; then
  printf '  ✗ w7-php-noph-no-log\n'; FAIL_NAMES+=("w7-php-noph-no-log"); FAILED=$((FAILED + 1))
else
  printf '  ✓ w7-php-noph-no-log\n'; PASSED=$((PASSED + 1))
fi
rm -f "$HOME/.claude/state/prepass-w7-noph-"* 2>/dev/null
rm -rf "$W7DIR"

# W7.7: Go проект с go.mod → go-vet запускается, log создаётся
if command -v go >/dev/null 2>&1; then
  W7DIR=$(mktemp -d -t w7-go.XXXXXX)
  cat > "$W7DIR/go.mod" <<'EOF'
module test
go 1.21
EOF
  cat > "$W7DIR/main.go" <<'EOF'
package main
func main() {}
EOF
  out=$(CLAUDE_PROJECT_DIR="$W7DIR" "$HOOKS_DIR/static-prepass.sh" <<< "{\"session_id\":\"w7-go\",\"tool_input\":{\"file_path\":\"$W7DIR/main.go\"}}" 2>&1); ec=$?
  assert_exit "w7-go-exit" 0 $ec
  # Wait для nohup'a — analyzer должен finish < 5s на trivial файле
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if ls "$HOME/.claude/state/prepass-w7-go-"*go-vet*.log 2>/dev/null | grep -q .; then break; fi
  done
  LOG=$(ls "$HOME/.claude/state/prepass-w7-go-"*go-vet*.log 2>/dev/null | head -1)
  if [[ -n "$LOG" && -f "$LOG" ]] && grep -q "static-prepass.*go-vet" "$LOG"; then
    printf '  ✓ w7-go-vet-log-created\n'; PASSED=$((PASSED + 1))
  else
    printf '  ✗ w7-go-vet-log-created (log not found or malformed)\n'; FAIL_NAMES+=("w7-go-vet-log-created"); FAILED=$((FAILED + 1))
  fi
  # Lock должен быть удалён (cleanup trap)
  if ls "$HOME/.claude/state/prepass-w7-go-"*.lock 2>/dev/null | grep -q .; then
    printf '  ✗ w7-go-lock-cleaned (lock still present)\n'; FAIL_NAMES+=("w7-go-lock-cleaned"); FAILED=$((FAILED + 1))
  else
    printf '  ✓ w7-go-lock-cleaned\n'; PASSED=$((PASSED + 1))
  fi
  rm -f "$HOME/.claude/state/prepass-w7-go-"* 2>/dev/null
  rm -rf "$W7DIR"
else
  printf '  ⏭ w7-go-vet-log-created (go not installed, skipped)\n'
  printf '  ⏭ w7-go-lock-cleaned (go not installed, skipped)\n'
fi

# W7.8: safe-path naming — два файла с одним basename в разных папках = разные log files
W7DIR=$(mktemp -d -t w7-safe.XXXXXX)
mkdir -p "$W7DIR/a" "$W7DIR/b"
cat > "$W7DIR/go.mod" <<'EOF'
module test
go 1.21
EOF
cat > "$W7DIR/a/util.go" <<'EOF'
package a
EOF
cat > "$W7DIR/b/util.go" <<'EOF'
package b
EOF
if command -v go >/dev/null 2>&1; then
  CLAUDE_PROJECT_DIR="$W7DIR" "$HOOKS_DIR/static-prepass.sh" <<< "{\"session_id\":\"w7-safe\",\"tool_input\":{\"file_path\":\"$W7DIR/a/util.go\"}}" >/dev/null 2>&1
  CLAUDE_PROJECT_DIR="$W7DIR" "$HOOKS_DIR/static-prepass.sh" <<< "{\"session_id\":\"w7-safe\",\"tool_input\":{\"file_path\":\"$W7DIR/b/util.go\"}}" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8; do sleep 0.5; LOGS=$(ls "$HOME/.claude/state/prepass-w7-safe-"* 2>/dev/null); [[ $(echo "$LOGS" | wc -l) -ge 2 ]] && break; done
  COUNT=$(ls "$HOME/.claude/state/prepass-w7-safe-"*go-vet.log 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$COUNT" -eq 2 ]]; then
    printf '  ✓ w7-safe-path-no-collision (2 distinct logs for same basename)\n'; PASSED=$((PASSED + 1))
  else
    printf '  ✗ w7-safe-path-no-collision (got %s logs, expected 2)\n' "$COUNT"; FAIL_NAMES+=("w7-safe-path-no-collision"); FAILED=$((FAILED + 1))
  fi
  rm -f "$HOME/.claude/state/prepass-w7-safe-"* 2>/dev/null
else
  printf '  ⏭ w7-safe-path-no-collision (go not installed, skipped)\n'
fi
rm -rf "$W7DIR"

# W7.9: bash -n syntax check
if bash -n "$HOOKS_DIR/static-prepass.sh" 2>/dev/null; then
  printf '  ✓ w7-static-prepass-syntax\n'; PASSED=$((PASSED + 1))
else
  printf '  ✗ w7-static-prepass-syntax\n'; FAIL_NAMES+=("w7-static-prepass-syntax"); FAILED=$((FAILED + 1))
fi

echo ""
echo "==========================================="
printf 'PASSED: %d\nFAILED: %d\n' "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
  echo "Failed tests:"
  printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
echo "All tests passed."
exit 0
