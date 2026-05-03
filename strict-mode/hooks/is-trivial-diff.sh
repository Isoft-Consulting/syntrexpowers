#!/usr/bin/env bash
# is-trivial-diff.sh — Wave 3 Phase 2 helper.
# Определяет: можно ли пропустить ФДР для текущего git diff.
#
# Skip ФДР если ВСЕ изменённые файлы попадают под:
#   - Whitespace-only changes (git diff -w пустой для файла)
#   - Comments-only changes (для PHP/Go/JS/TS — diff только в комментариях)
#   - Lockfiles без изменений в manifest (*.lock, package-lock, composer.lock, go.sum без go.mod)
#   - Translation/i18n bundles (lang/*.json, i18n/*.yml)
#
# DOCS НЕ TRIVIAL (по solidified правилу 2026-05-04): *.md/*.rst/*.txt/README/CHANGELOG
# триггерят ФДР через missing-verdict в Wave 2.5; в Wave 3 design — opt-in trailer
# `Strict-Skip-FDR: <reason>` в commit message (не реализовано в этой версии).
#
# Sensitive-paths override: если файл матчится с ~/.claude/sensitive-paths.txt — non-trivial,
# даже если попадает под skip-list (auth/payment/migrations docs могут содержать критику).
#
# Usage: is-trivial-diff.sh
#   stdin: ignored
#   args: optional --base <ref> (default HEAD)
#   exit 0 → trivial, skip FDR
#   exit 1 → not trivial, FDR mandatory
#   exit 2 → error / not in git repo (treated as non-trivial by callers)
#
# Запускается из cwd репозитория.

set -uo pipefail

BASE_REF="HEAD"
if [[ "${1:-}" = "--base" && -n "${2:-}" ]]; then
  BASE_REF="$2"
fi

# Не git repo → не можем определить, пусть FDR решит (return non-trivial с warning)
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "is-trivial-diff: not a git repository" >&2
  exit 1
fi

# Список изменённых файлов: modified+staged (git diff) + untracked (git ls-files).
# git diff пропускает untracked → новые файлы выглядят как «нет изменений», что false-trivial.
MODIFIED=$(git diff --name-only "$BASE_REF" 2>/dev/null)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
CHANGED=$(printf '%s\n%s\n' "$MODIFIED" "$UNTRACKED" | grep -v '^$' | sort -u)
if [[ -z "$CHANGED" ]]; then
  exit 0
fi

# Helper: tracked or not
is_untracked() {
  printf '%s\n' "$UNTRACKED" | grep -qxF "$1"
}

SENSITIVE_PATHS_FILE="$HOME/.claude/sensitive-paths.txt"

is_sensitive() {
  local file="$1"
  [[ -f "$SENSITIVE_PATHS_FILE" ]] || return 1
  printf '%s\n' "$file" | grep -E -q -f "$SENSITIVE_PATHS_FILE" 2>/dev/null
}

is_lockfile() {
  local file="$1"
  case "$file" in
    *.lock|package-lock.json|composer.lock|go.sum|yarn.lock|pnpm-lock.yaml|Cargo.lock|Pipfile.lock|poetry.lock)
      return 0 ;;
  esac
  return 1
}

is_translation() {
  local file="$1"
  case "$file" in
    lang/*.json|*/lang/*.json|i18n/*.yml|i18n/*.yaml|*/i18n/*.yml|*/i18n/*.yaml|locales/*.json|*/locales/*.json)
      return 0 ;;
  esac
  return 1
}

is_whitespace_only() {
  local file="$1"
  # git diff -w показывает diff игнорируя whitespace; пустой → различия только в whitespace
  local diff_w
  diff_w=$(git diff -w "$BASE_REF" -- "$file" 2>/dev/null)
  [[ -z "$diff_w" ]]
}

is_comments_only() {
  local file="$1"
  # Применимо только к языкам где комментарии // # /* *
  case "$file" in
    *.php|*.go|*.js|*.jsx|*.ts|*.tsx|*.py|*.rb|*.sh|*.bash)
      ;;
    *) return 1 ;;
  esac
  # Берём добавленные/удалённые строки (без diff-headers), смотрим: ВСЕ ли — комментарии?
  # Если хоть одна добавленная/удалённая строка не комментарий — НЕ comments-only.
  local non_comment_count
  non_comment_count=$(git diff "$BASE_REF" -- "$file" 2>/dev/null \
    | awk '
      /^[+-][^+-]/ {
        line=$0
        sub(/^[+-][[:space:]]*/, "", line)
        # Skip empty lines
        if (line == "") next
        # Comment patterns: //, #, /*, * (продолжение блочного), */
        if (line ~ /^(\/\/|#|\/\*|\*[^\/]|\*\/)/) next
        # Иначе это код
        print "code"
      }' | grep -c "code")
  [[ "$non_comment_count" -eq 0 ]]
}

# go.mod check — если в diff есть go.sum но НЕТ go.mod → lockfile-only OK.
# Если есть go.mod → не trivial (manifest changed).
HAS_GO_MOD_CHANGE=false
if printf '%s\n' "$CHANGED" | grep -q "^go\.mod$\|/go\.mod$"; then
  HAS_GO_MOD_CHANGE=true
fi

# Проверяем каждый файл — находим хоть один non-trivial → exit 1
while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  # Sensitive override
  if is_sensitive "$file"; then
    exit 1
  fi

  # Untracked (новый файл): допустимо trivial только если lockfile/translation.
  # Whitespace/comments-only checks недоступны (нет git history для diff).
  if is_untracked "$file"; then
    if is_lockfile "$file"; then continue; fi
    if is_translation "$file"; then continue; fi
    # Любой другой новый файл — non-trivial (включая *.md, *.txt, code и т.д.)
    exit 1
  fi

  # Tracked & modified — полный набор проверок.
  if is_whitespace_only "$file"; then continue; fi
  if is_lockfile "$file"; then
    if [[ "$file" == "go.sum" || "$file" == */go.sum ]] && $HAS_GO_MOD_CHANGE; then
      exit 1
    fi
    continue
  fi
  if is_translation "$file"; then continue; fi
  if is_comments_only "$file"; then continue; fi

  exit 1
done <<< "$CHANGED"

# Все файлы прошли как trivial
exit 0
