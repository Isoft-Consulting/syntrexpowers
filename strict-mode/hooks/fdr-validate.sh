#!/usr/bin/env bash
# fdr-validate.sh — Wave 3 Phase 2 валидатор FDR-артефакта.
#
# Проверяет fdr-<sid>.md по 11 правилам (C1-C11) из spec §4.2.1.
#
# Usage:
#   fdr-validate.sh <path-to-fdr-artifact> <path-to-edits-log>
#
# Exit codes:
#   0 → артефакт валиден
#   2 → ошибка валидации (stderr: список fail'ов с C-номерами)
#   1 → internal error (нет аргументов, нет deps)
#
# Stdout: ничего при success. Stderr: подробности fail'ов.

set -uo pipefail

ARTIFACT="${1:-}"
EDITS_LOG="${2:-}"
SID="${3:-}"  # optional, для C11 bypass-проверки

if [[ -z "$ARTIFACT" || -z "$EDITS_LOG" ]]; then
  echo "fdr-validate: usage: fdr-validate.sh <artifact> <edits-log> [sid]" >&2
  exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
  echo "fdr-validate: awk required" >&2
  exit 1
fi

FAILS=()

# === C11: bypass пропускает валидацию ===
if [[ -n "$SID" ]]; then
  BYPASS="$HOME/.claude/state/bypass-${SID}"
  if [[ -f "$BYPASS" ]]; then
    REASON=$(cat "$BYPASS" 2>/dev/null)
    if [[ -n "$REASON" ]]; then
      # Логируем bypass и удаляем файл (одноразовый)
      mkdir -p "$HOME/.claude/state" 2>/dev/null
      printf '{"ts":"%s","sid":"%s","reason":%s,"source":"fdr-validate"}\n' \
        "$(date -Iseconds 2>/dev/null || date)" "$SID" "$(printf '%s' "$REASON" | jq -Rs . 2>/dev/null || echo '""')" \
        >> "$HOME/.claude/state/bypass-log.jsonl" 2>/dev/null
      rm -f "$BYPASS" 2>/dev/null
      exit 0
    fi
  fi
fi

# === C1: файл существует ===
if [[ ! -f "$ARTIFACT" ]]; then
  echo "C1 FAIL: FDR artifact missing — run /fdr to generate $ARTIFACT" >&2
  exit 2
fi

ARTIFACT_BODY=$(cat "$ARTIFACT" 2>/dev/null)
if [[ -z "$ARTIFACT_BODY" ]]; then
  echo "C1 FAIL: FDR artifact is empty: $ARTIFACT" >&2
  exit 2
fi

# === C2: каждый файл из edits-log в ## Scope ===
if [[ -f "$EDITS_LOG" ]]; then
  # Извлекаем секцию Scope (между "## Scope" и следующим "## ")
  SCOPE_BLOCK=$(printf '%s\n' "$ARTIFACT_BODY" | awk '
    /^## Scope$/ { in_scope=1; next }
    /^## / && in_scope { exit }
    in_scope { print }
  ')

  while IFS= read -r edited_file; do
    [[ -z "$edited_file" ]] && continue
    # Пропускаем не-существующие файлы (worktree edits, удалённые файлы)
    [[ ! -e "$edited_file" ]] && continue
    # Ищем в Scope блоке (может быть basename или fullpath)
    base=$(basename "$edited_file")
    if ! printf '%s' "$SCOPE_BLOCK" | grep -qF -- "$edited_file" \
       && ! printf '%s' "$SCOPE_BLOCK" | grep -qF -- "$base"; then
      FAILS+=("C2 FAIL: Scope incomplete — missing $edited_file (or $base)")
    fi
  done < <(sort -u "$EDITS_LOG" 2>/dev/null)
fi

# === C3-C5, C10: parse Findings ===
# Findings секция: каждый ### F<n> блок до следующего ### или ##.
# Парсинг через awk → temp-файл per finding (надёжнее чем bash IFS multi-char).
FINDINGS_DIR=$(mktemp -d -t fdr-findings.XXXXXX 2>/dev/null) || {
  echo "fdr-validate: cannot create tempdir (ENOSPC / TMPDIR unwritable)" >&2
  exit 1
}
trap 'rm -rf "$FINDINGS_DIR" 2>/dev/null' EXIT

printf '%s\n' "$ARTIFACT_BODY" | awk -v outdir="$FINDINGS_DIR" '
  BEGIN { in_findings=0; current_id=""; current_file="" }
  /^## Findings$/ { in_findings=1; next }
  /^## / && in_findings && !/^## Findings/ {
    in_findings=0; current_id=""; current_file=""; next
  }
  in_findings && /^### F[0-9]+/ {
    current_id=$2
    sub(/^### /, "", current_id)
    current_file=outdir "/" current_id ".txt"
    next
  }
  in_findings && current_file != "" {
    print >> current_file
  }
'

OPEN_COUNT=0
RESOLVED_COUNT=0
HAS_FINDINGS=false

for ffile in "$FINDINGS_DIR"/F*.txt; do
  [[ -f "$ffile" ]] || continue
  HAS_FINDINGS=true
  fid=$(basename "$ffile" .txt)
  body=$(cat "$ffile")

  # Required fields
  for field in file layer scenario expected actual severity status; do
    if ! printf '%s' "$body" | grep -qiE "^${field}:"; then
      FAILS+=("C3 FAIL: Finding $fid missing field '$field'")
    fi
  done

  # severity (C4)
  sev=$(printf '%s' "$body" | grep -iE "^severity:" | head -1 | awk -F': *' '{print toupper($2)}' | tr -d '[:space:]')
  case "$sev" in
    CRITICAL|HIGH|MEDIUM|LOW) ;;
    *) FAILS+=("C4 FAIL: Finding $fid invalid severity '$sev' (must be CRITICAL|HIGH|MEDIUM|LOW)") ;;
  esac

  # CRITICAL/HIGH → require :line (C3 amendment).
  # sed (не awk -F): awk's split на ': ' разбил бы 'app/x.php:42' на 3 поля и потерял ':42'.
  if [[ "$sev" = "CRITICAL" || "$sev" = "HIGH" ]]; then
    file_line=$(printf '%s' "$body" | grep -iE "^file:" | head -1 | sed -E 's/^[Ff]ile:[[:space:]]*//' | tr -d '[:space:]')
    if ! [[ "$file_line" =~ :[0-9]+ ]]; then
      FAILS+=("C3 FAIL: Finding $fid severity=$sev requires file:line (got '$file_line')")
    fi
  fi

  # status (C5)
  st=$(printf '%s' "$body" | grep -iE "^status:" | head -1 | awk -F': *' '{print tolower($2)}' | tr -d '[:space:]')
  case "$st" in
    open) OPEN_COUNT=$((OPEN_COUNT+1)) ;;
    resolved) RESOLVED_COUNT=$((RESOLVED_COUNT+1)) ;;
    reopened|partial) ;;
    *) FAILS+=("C5 FAIL: Finding $fid invalid status '$st' (must be open|resolved|reopened|partial)") ;;
  esac

  # C10
  if [[ "$st" = "resolved" ]]; then
    if ! printf '%s' "$body" | grep -qiE "^fix-commit:[[:space:]]*[a-f0-9]{6,}|^fix-commit:[[:space:]]*pending"; then
      FAILS+=("C10 FAIL: Finding $fid resolved but missing 'fix-commit: <sha|pending>'")
    fi
    if ! printf '%s' "$body" | grep -qiE "^re-check:"; then
      FAILS+=("C10 FAIL: Finding $fid resolved but missing 're-check: <ISO> — <verifier>'")
    fi
  fi
done

# === C6: Verdict format ===
# Должны быть две строки:
#   status: <complete|incomplete|degraded>
#   counts: N open / M resolved

VERDICT_BLOCK=$(printf '%s\n' "$ARTIFACT_BODY" | awk '
  /^## Verdict$/ { in_v=1; next }
  /^## / && in_v { exit }
  in_v { print }
')

if [[ -z "$VERDICT_BLOCK" ]]; then
  FAILS+=("C6 FAIL: missing '## Verdict' section")
else
  V_STATUS=$(printf '%s' "$VERDICT_BLOCK" | grep -E "^status:" | head -1)
  V_COUNTS=$(printf '%s' "$VERDICT_BLOCK" | grep -E "^counts:" | head -1)

  if ! [[ "$V_STATUS" =~ ^status:[[:space:]]*(complete|incomplete|degraded)[[:space:]]*$ ]]; then
    FAILS+=("C6 FAIL: Verdict status line invalid — expected 'status: <complete|incomplete|degraded>', got '$V_STATUS'")
  fi
  if ! [[ "$V_COUNTS" =~ ^counts:[[:space:]]*[0-9]+[[:space:]]+open[[:space:]]+/[[:space:]]+[0-9]+[[:space:]]+resolved[[:space:]]*$ ]]; then
    FAILS+=("C6 FAIL: Verdict counts line invalid — expected 'counts: N open / M resolved', got '$V_COUNTS'")
  fi

  # C6b: open findings → status НЕ complete
  if [[ "$OPEN_COUNT" -gt 0 ]] && [[ "$V_STATUS" =~ status:[[:space:]]*complete ]]; then
    FAILS+=("C6 FAIL: $OPEN_COUNT open findings exist but Verdict says 'complete' (must be incomplete or degraded)")
  fi
fi

# === C7: cycles >= 2 если findings были и все resolved ===
CYCLES=$(printf '%s' "$ARTIFACT_BODY" | grep -E "^cycles:[[:space:]]*[0-9]+" | head -1 | awk -F': *' '{print $2}' | tr -d '[:space:]')
CYCLES=${CYCLES:-1}

if [[ "$RESOLVED_COUNT" -gt 0 && "$OPEN_COUNT" -eq 0 && "$CYCLES" -lt 2 ]]; then
  FAILS+=("C7 FAIL: $RESOLVED_COUNT findings resolved but cycles=$CYCLES (need re-check cycle, cycles must be ≥ 2)")
fi

# === C8: запрещённые секции/фразы ===
# Headings
if printf '%s' "$ARTIFACT_BODY" | grep -qiE '^#{1,3}[[:space:]]+(coverage|progress|history|highlights|summary|резюме|что проверено|что было сделано|recap|обзор|заметки|notes)\b'; then
  match=$(printf '%s' "$ARTIFACT_BODY" | grep -iE '^#{1,3}[[:space:]]+(coverage|progress|history|highlights|summary|резюме|что проверено|что было сделано|recap|обзор|заметки|notes)\b' | head -1)
  FAILS+=("C8 FAIL: forbidden section header — '$match'")
fi
# Inline phrases
if printf '%s' "$ARTIFACT_BODY" | grep -qiE '\b(great job|хорошо сделано|молодец|kudos|отлично|nicely done|well done|good work)\b'; then
  match=$(printf '%s' "$ARTIFACT_BODY" | grep -oiE '\b(great job|хорошо сделано|молодец|kudos|отлично|nicely done|well done|good work)\b' | head -1)
  FAILS+=("C8 FAIL: forbidden praise phrase — '$match'")
fi

# === C9: Layer 0 (static prepass) если Phase 4 active И есть php/go/ts/js ===
# Phase 4 active = существует static-prepass.sh
if [[ -x "$HOME/.claude/hooks/static-prepass.sh" ]]; then
  HAS_CODE_FILE=false
  if [[ -f "$EDITS_LOG" ]]; then
    while IFS= read -r ef; do
      case "$ef" in
        *.php|*.go|*.ts|*.tsx|*.js|*.jsx) HAS_CODE_FILE=true; break ;;
      esac
    done < "$EDITS_LOG"
  fi
  if $HAS_CODE_FILE; then
    if ! printf '%s' "$ARTIFACT_BODY" | grep -qE "^## Layer 0"; then
      FAILS+=("C9 FAIL: Static prepass active (Phase 4) but '## Layer 0' section missing in artifact")
    fi
  fi
fi

# === Result ===
if [[ ${#FAILS[@]} -gt 0 ]]; then
  printf 'fdr-validate: %d check(s) failed:\n' "${#FAILS[@]}" >&2
  printf '  %s\n' "${FAILS[@]}" >&2
  exit 2
fi

exit 0
