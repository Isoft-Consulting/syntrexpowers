#!/usr/bin/env bash
# install.sh — Claude Code Strict Mode installer (Wave 1 + Wave 2 + Wave 2.5).
# Идемпотентен: можно запускать многократно, ничего не сломает.
# Делает: бекап текущего состояния, копирует hooks, мерджит settings.json, тестирует.
# Не трогает существующий ~/.claude/CLAUDE.md если он есть (только показывает diff с шаблоном).
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
STATE_DIR="$CLAUDE_DIR/state"
BACKUP_DIR="$CLAUDE_DIR/backups"
DATE_TAG=$(date +%Y-%m-%d-%H%M%S)

echo "===================================================="
echo "Claude Code Strict Mode installer"
echo "Bundle:    $BUNDLE_DIR"
echo "Target:    $CLAUDE_DIR"
echo "Date tag:  $DATE_TAG"
echo "===================================================="
echo ""

# ----- 1. Dependency check -----
echo "[1/7] Проверка зависимостей..."
MISSING_REQUIRED=()
MISSING_OPTIONAL=()
for cmd in jq git python3 awk; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_REQUIRED+=("$cmd")
done
HAS_TIMEOUT=true
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  HAS_TIMEOUT=false
  if [[ "${1:-}" = "--enable-wave3" ]]; then
    MISSING_REQUIRED+=("timeout (требуется для Wave 3 verifier; brew install coreutils)")
  else
    MISSING_OPTIONAL+=("timeout (Wave 2.5 judge будет работать без timeout-обёртки; для Wave 3 нужен brew install coreutils)")
  fi
fi
if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
  echo "  FATAL: missing required dependencies:"
  printf '    - %s\n' "${MISSING_REQUIRED[@]}"
  echo "  Install via: brew install jq git python3 coreutils"
  exit 1
fi
echo "  ✓ jq, git, python3, awk"
if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
  echo "  ⚠ optional warnings:"
  printf '    - %s\n' "${MISSING_OPTIONAL[@]}"
fi
$HAS_TIMEOUT && echo "  ✓ timeout"

# ----- 2. Создать каталоги -----
echo "[2/7] Создание каталогов..."
mkdir -p "$HOOKS_DIR/tests" "$STATE_DIR" "$BACKUP_DIR" "$CLAUDE_DIR/specs"
echo "  ✓ $HOOKS_DIR, $STATE_DIR, $BACKUP_DIR, $CLAUDE_DIR/specs"

# ----- 3. Бекап существующих файлов -----
echo "[3/7] Бекап существующих файлов..."
for f in CLAUDE.md settings.json settings.local.json sensitive-paths.txt stub-allowlist.txt; do
  if [[ -f "$CLAUDE_DIR/$f" ]]; then
    cp "$CLAUDE_DIR/$f" "$BACKUP_DIR/${f}.bak-${DATE_TAG}"
    echo "  ✓ backed up $f → backups/${f}.bak-${DATE_TAG}"
  fi
done

# ----- 4. Копирование hook-скриптов -----
echo "[4/7] Установка хуков..."
WAVE2_HOOKS=(health-check.sh prompt-inject.sh pre-write-scan.sh record-edit.sh stop-guard.sh stub-scan.sh fdr-challenge.sh judge.sh prune-mem.py)
WAVE3_HOOKS=(is-trivial-diff.sh fdr-validate.sh static-prepass.sh)
WAVE4_HOOKS=(pre-destructive.sh destructive-judge.sh)

# Orphan cleanup: предыдущие install runs могли оставить .new.<PID> файлы при kill
# mid-cp. Sweep'аем перед deploy чтобы избежать накопления (~5KB × N kills).
# nullglob: если matches нет — pattern expands to пустой список (а не литерал).
# CONCURRENT SAFETY: skip files младше 60s — это потенциально активный .new.PID
# другого параллельного install. cp на 5KB hook занимает миллисекунды, активные
# никогда не попадут под 60-second threshold. Любой .new.* старше 60s — точно
# orphan от прошлого killed install.
ORPHAN_COUNT=0
ORPHAN_SKIPPED=0
NOW_EPOCH=$(date +%s)
shopt -s nullglob
for orphan in "$HOOKS_DIR"/*.new.* "$HOOKS_DIR"/tests/*.new.*; do
  [[ -f "$orphan" ]] || continue
  # GNU first: Linux `stat -f %m` = mountpoint (filesystem stats), не mtime epoch.
  ORPHAN_MTIME=$(stat -c %Y "$orphan" 2>/dev/null || stat -f %m "$orphan" 2>/dev/null || echo 0)
  AGE=$(( NOW_EPOCH - ORPHAN_MTIME ))
  if [[ "$AGE" -lt 60 ]]; then
    ORPHAN_SKIPPED=$((ORPHAN_SKIPPED + 1))
    continue
  fi
  rm -f "$orphan" 2>/dev/null && ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
done
shopt -u nullglob
[[ "$ORPHAN_COUNT" -gt 0 ]] && echo "  ↻ swept $ORPHAN_COUNT orphan .new.* file(s) from prior interrupted install"
[[ "$ORPHAN_SKIPPED" -gt 0 ]] && echo "  ⏸ skipped $ORPHAN_SKIPPED .new.* younger than 60s (likely active concurrent install)"

# Atomic deploy helper: cp в .new + chmod + atomic mv через rename(2) на той же FS.
# Passive safety guarantees:
#   - POSIX cp НЕ atomic (open O_TRUNC + write loop) — kill mid-copy = partial .new.PID
#   - mv на same FS использует rename(2), POSIX-atomic — dst либо старый, либо новый
#   - kill между cp и mv → .new.PID orphan + dst untouched (cleanup-сweep на следующем install)
#   - kill внутри cp → .new.PID partial + dst untouched (cleanup на следующем install)
# Trap на EXIT/INT/TERM удаляет наш текущий .new.PID если script killed.
# НЕ guarantees: fsync перед mv (теоретически possible data-loss на reboot mid-deploy
# для hooks ~5KB на современной SSD pagecache flush window единицы ms; mitigation —
# повторный install).
ACTIVE_TMP=""
cleanup_active_tmp() { [[ -n "$ACTIVE_TMP" && -f "$ACTIVE_TMP" ]] && rm -f "$ACTIVE_TMP" 2>/dev/null; }
trap cleanup_active_tmp EXIT INT TERM

atomic_deploy() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$"
  ACTIVE_TMP="$tmp"
  cp "$src" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$dst"
  ACTIVE_TMP=""
}

# Collision-resistant backup naming: timestamp + PID + filename.
# `$(date +%Y%m%d-%H%M%S)` granularity 1 sec — re-deploy в одну секунду overwrites.
# Добавляем PID ($$). Filename различает разные хуки в одном install run.
# (Counter был бы избыточен — install бекапит каждый file ровно один раз; и реализация
# через subshell counter mutation НЕ работает: $() порождает subshell, изменение
# переменной не persist в parent.)
backup_unique_path() {
  local f="$1"
  echo "$BACKUP_DIR/${f}.bak-${DATE_TAG}-$$"
}

for f in "${WAVE2_HOOKS[@]}" "${WAVE3_HOOKS[@]}" "${WAVE4_HOOKS[@]}"; do
  if [[ -f "$BUNDLE_DIR/hooks/$f" ]]; then
    # Бекап существующего хука перед перезаписью (collision-resistant naming).
    if [[ -f "$HOOKS_DIR/$f" ]] && ! cmp -s "$BUNDLE_DIR/hooks/$f" "$HOOKS_DIR/$f"; then
      backup_path=$(backup_unique_path "$f")
      cp "$HOOKS_DIR/$f" "$backup_path"
      echo "  ↺ backed up $f → ${backup_path##*/}"
    fi
    atomic_deploy "$BUNDLE_DIR/hooks/$f" "$HOOKS_DIR/$f"
    echo "  ✓ $f"
  fi
done
atomic_deploy "$BUNDLE_DIR/hooks/tests/run-tests.sh" "$HOOKS_DIR/tests/run-tests.sh"
echo "  ✓ tests/run-tests.sh"

# ----- 5. Templates (sensitive-paths, stub-allowlist) -----
echo "[5/7] Templates..."
if [[ ! -f "$CLAUDE_DIR/sensitive-paths.txt" ]]; then
  cp "$BUNDLE_DIR/templates/sensitive-paths.txt" "$CLAUDE_DIR/sensitive-paths.txt"
  echo "  ✓ sensitive-paths.txt (новый, шаблон)"
else
  echo "  ⏭ sensitive-paths.txt уже существует, не трогаю"
fi
if [[ ! -f "$CLAUDE_DIR/stub-allowlist.txt" ]]; then
  cp "$BUNDLE_DIR/templates/stub-allowlist.txt" "$CLAUDE_DIR/stub-allowlist.txt"
  echo "  ✓ stub-allowlist.txt (пустой шаблон с примерами)"
else
  echo "  ⏭ stub-allowlist.txt уже существует, не трогаю"
fi
# Wave 4: destructive-patterns.txt + protected-paths.txt
if [[ ! -f "$CLAUDE_DIR/destructive-patterns.txt" ]]; then
  cp "$BUNDLE_DIR/templates/destructive-patterns.txt" "$CLAUDE_DIR/destructive-patterns.txt"
  echo "  ✓ destructive-patterns.txt (Wave 4 templates)"
else
  echo "  ⏭ destructive-patterns.txt уже существует, не трогаю"
fi
if [[ ! -f "$CLAUDE_DIR/protected-paths.txt" ]]; then
  cp "$BUNDLE_DIR/templates/protected-paths.txt" "$CLAUDE_DIR/protected-paths.txt"
  echo "  ✓ protected-paths.txt (Wave 4 templates)"
else
  echo "  ⏭ protected-paths.txt уже существует, не трогаю"
fi
cp "$BUNDLE_DIR/docs/claude-code-strict-mode-v1.md" "$CLAUDE_DIR/specs/claude-code-strict-mode-v1.md"
echo "  ✓ specs/claude-code-strict-mode-v1.md"

# ----- 6. CLAUDE.md handling -----
echo "[6/7] CLAUDE.md..."
if [[ ! -f "$CLAUDE_DIR/CLAUDE.md" ]]; then
  cp "$BUNDLE_DIR/templates/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  echo "  ✓ CLAUDE.md установлен из template (universal rules)"
else
  echo "  ⏭ CLAUDE.md существует — НЕ трогаю."
  echo "    Чтобы получить universal-правила strict-mode добавь в свой:"
  echo "      cat $BUNDLE_DIR/templates/CLAUDE.md >> $CLAUDE_DIR/CLAUDE.md"
  echo "    Или открой template вручную и забери только нужные секции."
fi

# ----- 7. settings.json merge -----
echo "[7/7] Мердж settings.json (hooks block + permissions)..."
# python3 heredoc не получает $* / sys.argv от bash — передаём флаг через bash var expansion.
# Без этого "--enable-wave3" флаг был silently ignored (bug в оригинальном install.sh).
ENABLE_WAVE3=false
for arg in "$@"; do [[ "$arg" = "--enable-wave3" ]] && ENABLE_WAVE3=true; done

python3 <<EOF
import json, sys
from pathlib import Path

p = Path("$CLAUDE_DIR/settings.json")
if p.exists():
    s = json.loads(p.read_text())
else:
    s = {}

# Merge hooks
hooks_block = {
    "SessionStart": [
        {"hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/health-check.sh", "timeout": 5000}]}
    ],
    "UserPromptSubmit": [
        {"hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/prompt-inject.sh", "timeout": 3000}]}
    ],
    "PreToolUse": [
        {"matcher": "Write|Edit|MultiEdit",
         "hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/pre-write-scan.sh", "timeout": 5000}]},
        {"matcher": "Bash",
         "hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/pre-destructive.sh", "timeout": 5000}]}
    ],
    "PostToolUse": [
        {"matcher": "Write|Edit|MultiEdit",
         "hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/record-edit.sh", "timeout": 3000}]}
    ],
    "Stop": [
        {"hooks": [
            {"type": "command", "command": "\$HOME/.claude/hooks/stop-guard.sh", "timeout": 30000},
            {"type": "command", "command": "\$HOME/.claude/hooks/fdr-challenge.sh", "timeout": 60000}
        ]}
    ],
    "SubagentStop": [
        {"hooks": [{"type": "command", "command": "\$HOME/.claude/hooks/stop-guard.sh", "timeout": 30000}]}
    ],
}

existing = s.get("hooks", {})
# Соединяем без дубликатов: для каждого event-name добавляем наши хуки если их там нет.
for evt, our_groups in hooks_block.items():
    existing.setdefault(evt, [])
    our_cmds = {h["command"] for grp in our_groups for h in grp["hooks"]}
    existing_cmds = {h["command"] for grp in existing[evt] for h in grp.get("hooks", [])}
    if not (our_cmds & existing_cmds):
        existing[evt].extend(our_groups)
s["hooks"] = existing

# Permissions: Skill(*) и Agent(*) добавляются ТОЛЬКО при --enable-wave3 флаге
# (Wave 1+2+2.5 их не используют, опен permissions без consumer = unnecessary surface)
# Флаг передаётся из bash через ENABLE_WAVE3 env (heredoc не имеет sys.argv).
enable_wave3 = "${ENABLE_WAVE3}" == "true"
if enable_wave3:
    perms = s.setdefault("permissions", {}).setdefault("allow", [])
    for needed in ["Skill(*)", "Agent(*)"]:
        if needed not in perms:
            perms.append(needed)
    print("  ✓ Wave 3 permissions added (Skill, Agent)")

    # Wave 3 hook registrations: static-prepass.sh добавляется в PostToolUse chain
    # (Phase 4). Stop hook timeout повышается до 120000ms для fdr-verify.sh (Phase 5).
    static_prepass_cmd = "\$HOME/.claude/hooks/static-prepass.sh"
    posttool = s.get("hooks", {}).get("PostToolUse", [])
    for grp in posttool:
        existing_cmds = {h.get("command") for h in grp.get("hooks", [])}
        if static_prepass_cmd not in existing_cmds:
            grp.setdefault("hooks", []).append({
                "type": "command",
                "command": static_prepass_cmd,
                "timeout": 3000,
            })
    print("  ✓ Wave 3 PostToolUse hook registered (static-prepass.sh)")

tmp = p.with_suffix(".json.tmp")
tmp.write_text(json.dumps(s, indent=2, ensure_ascii=False))
tmp.replace(p)
print("  ✓ settings.json updated (hooks + permissions)")
EOF

echo ""
echo "===================================================="
echo "Установка завершена. Запускаю тесты..."
echo "===================================================="
echo ""
bash "$HOOKS_DIR/tests/run-tests.sh" 2>&1 | tail -5

echo ""
echo "===================================================="
echo "Готово. Что дальше:"
echo "  1. Открой НОВУЮ сессию Claude Code (settings.json читается на старте сессии)"
echo "  2. Проверь активацию: при старте может быть warning от health-check"
echo "  3. Документация: $CLAUDE_DIR/specs/claude-code-strict-mode-v1.md"
echo "  4. Bypass при ложном срабатывании: см. сообщение блока (path к bypass-файлу)"
echo "  5. Откат: $BUNDLE_DIR/uninstall.sh"
echo "===================================================="
