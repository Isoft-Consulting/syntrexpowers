#!/usr/bin/env bash
# health-check.sh — SessionStart hook.
# Проверяет наличие критичных зависимостей. Молчит если всё в порядке.
# stdout попадает в context модели как additionalContext.
set -uo pipefail

# Recursion guard: nested claude -p вызовы (judge.sh / fdr-verify.sh) — skip health-check.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

PROBLEMS=()

for cmd in jq git python3 awk; do
  command -v "$cmd" >/dev/null 2>&1 || PROBLEMS+=("missing dep: $cmd")
done

# timeout: macOS поставляет gtimeout через coreutils
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  PROBLEMS+=("missing dep: timeout (brew install coreutils — для verifier)")
fi

# state-каталог должен существовать (создаём, если нет)
mkdir -p "$HOME/.claude/state" 2>/dev/null || true

# Сторожевой замер: размер CLAUDE.md (если резко вырос — хорошее место для предупреждения)
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
  SIZE=$(wc -c < "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo 0)
  if [[ ${SIZE:-0} -gt 16000 ]]; then
    PROBLEMS+=("warning: ~/.claude/CLAUDE.md = ${SIZE} bytes (рассмотри prune-mem.py)")
  fi
fi

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
  echo "[strict-mode health-check]"
  printf '  - %s\n' "${PROBLEMS[@]}"
fi

exit 0
