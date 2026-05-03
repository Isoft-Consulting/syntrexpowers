#!/usr/bin/env bash
# fdr-challenge.sh — Stop hook (Wave 2.5 + judge).
# Многоцикловая FDR-проверка с Haiku-судьёй и failsafe cap.
#
# State machine:
#   - Нет history-файла → cycle 0: detect verdict + FDR context → block initial challenge
#   - History есть → cycle N: judge классифицирует ответ:
#       complete   → удалить history, allow Stop
#       substantive→ продолжить, добавить cycle entry, block с reason "продолжай"
#       evasive    → block с targeted gaps_to_demand из judge
#       repetitive → инкрементировать repetition counter; 2 подряд → allow
#       unknown    → fallback: allow с warning в log
#   - Failsafe cap (10 циклов) → allow в любом случае
#
# Bypass: создать файл $STATE/bypass-<sid> с reason — одноразовый.
# Project opt-out: <project>/.claude/strict-mode.disabled.
# Disable judge globally: env STRICT_NO_HAIKU_JUDGE=1 → fallback к старому one-shot regex.
set -uo pipefail

# Recursion guard (см. prompt-inject.sh): не файрить challenge для вложенного claude -p
# (judge.sh, fdr-verify.sh, triage). Иначе судья получит свой собственный challenge.
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
HOOK_TYPE=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')

[[ -z "$SID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0
# Subagent stops пропускаем.
[[ "$HOOK_TYPE" = "SubagentStop" ]] && exit 0
[[ "$TRANSCRIPT" == *"/subagents/"* ]] && exit 0

SAFE_SID=$(printf '%s' "$SID" | tr -cd '[:alnum:]-_')
[[ -z "$SAFE_SID" ]] && exit 0

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

HISTORY_FILE="$STATE_DIR/fdr-cycles-$SAFE_SID.jsonl"
BYPASS_FILE="$STATE_DIR/bypass-$SAFE_SID"
HASHES_FILE="$STATE_DIR/fired-hashes-$SAFE_SID.log"
LOG_FILE="$STATE_DIR/stop-guard.log"
FAILSAFE_CAP=10
STALE_AGE_SEC=1800   # 30 минут без активности — history считается stale

log_decision() {
  local action="$1" rationale="$2"
  local ts_now extra=""
  ts_now="$(date -Iseconds 2>/dev/null || date)"
  # Extra observability поля (выводятся как индентированные подстроки):
  [[ -n "${MATCHED_PATTERN:-}" ]] && extra+=$'\n  matched: '"$MATCHED_PATTERN"
  [[ -n "${EXTRACTED_TS:-}" ]] && extra+=$'\n  extracted_from_ts: '"$EXTRACTED_TS"
  [[ -n "${LAG_MINUTES:-}" ]] && extra+=$'\n  lag_minutes: '"$LAG_MINUTES"
  [[ -n "${TRANSCRIPT_LAST_TS:-}" && "${TRANSCRIPT_LAST_TS}" != "${EXTRACTED_TS:-}" ]] && extra+=$'\n  transcript_last_ts: '"$TRANSCRIPT_LAST_TS (newer than extracted — possible race)"
  printf '%s\tfdr-challenge\tSID=%s\tcycle=%s\t%s\t%s%s\n' \
    "$ts_now" "$SAFE_SID" "${CYCLE:-0}" "$action" "$rationale" "$extra" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Bypass — clear + exit
if [[ -f "$BYPASS_FILE" ]]; then
  REASON=$(cat "$BYPASS_FILE" 2>/dev/null)
  if [[ -n "$REASON" ]]; then
    rm -f "$BYPASS_FILE" "$HISTORY_FILE" 2>/dev/null || true
    CYCLE=0
    log_decision "bypass" "$REASON"
    exit 0
  fi
fi

# Project opt-out
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -f "$PROJECT_DIR/.claude/strict-mode.disabled" ]] && exit 0

# Defensive: если history файл старше STALE_AGE_SEC — считаем зависшим (broken cycle от
# old timeout, network failure judge'а etc), сбрасываем. Иначе stale state блокирует все
# следующие сессии этого SID после рестарта.
if [[ -f "$HISTORY_FILE" ]]; then
  HIST_MTIME=$(stat -f %m "$HISTORY_FILE" 2>/dev/null || stat -c %Y "$HISTORY_FILE" 2>/dev/null || echo 0)
  HIST_AGE=$(( $(date +%s) - HIST_MTIME ))
  if [[ "$HIST_AGE" -gt "$STALE_AGE_SEC" ]]; then
    rm -f "$HISTORY_FILE" 2>/dev/null || true
    log_decision "reset" "stale history age=${HIST_AGE}s > ${STALE_AGE_SEC}s"
  fi
fi

# Определить текущий cycle
CYCLE=0
if [[ -f "$HISTORY_FILE" ]]; then
  CYCLE=$(wc -l < "$HISTORY_FILE" 2>/dev/null | tr -d ' ' || echo 0)
fi

# Failsafe cap
if [[ "${CYCLE:-0}" -ge "$FAILSAFE_CAP" ]]; then
  rm -f "$HISTORY_FILE" 2>/dev/null || true
  log_decision "allow" "failsafe cap=$FAILSAFE_CAP reached"
  exit 0
fi

# Mitigation для race condition: Claude Code может писать assistant message в transcript
# с лагом (буферизация node.js streams, OS write buffer). Sleep даёт файлу время зафлашиться.
# Default 2000ms — баланс между надёжностью и UX-лагом на Stop. На 50 Stops/day = ~100s overhead.
# Override через STRICT_HOOK_READ_DELAY_MS=N (0 = disable, например для тестов).
DELAY_MS="${STRICT_HOOK_READ_DELAY_MS:-2000}"
# Validate numeric (защита от garbage env value)
if ! [[ "$DELAY_MS" =~ ^[0-9]+$ ]]; then DELAY_MS=2000; fi
if [[ "$DELAY_MS" -gt 0 ]]; then
  sleep "$(awk "BEGIN { print $DELAY_MS / 1000 }")"
fi

# Извлечь последнее non-empty assistant-text — ТОЛЬКО из ТЕКУЩЕГО ТУРНА (после последнего
# user message). Это критично: иначе hook lookback'ает в предыдущие турны и файрит
# на stale verdicts которых пользователь уже не видит как «текущее».
# Алгоритм:
#   1. Найти индекс последнего user message в tail-200
#   2. Взять только assistant messages ПОСЛЕ этого индекса (= current turn)
#   3. Из них last non-empty text
# Возвращается в формате "TIMESTAMP|||TEXT".
LAST_RECORD=$(tail -n 200 "$TRANSCRIPT" 2>/dev/null | jq -rs '
  (length - 1 - (reverse | map(.type == "user") | index(true) // length)) as $u
  | .[$u+1:]
  | map(select(.type == "assistant"))
  | map({ts: .timestamp, content: (.message.content // .text // empty
      | if type == "array" then map(select(.type? == "text") | .text? // "") | join("\n") else tostring end)})
  | map(select(.content | length > 0))
  | if length == 0 then "" else (last | .ts + "|||" + .content) end
' 2>/dev/null)

if [[ -z "$LAST_RECORD" || "$LAST_RECORD" != *"|||"* ]]; then
  TRANSCRIPT_TAIL=$(tail -n 3 "$TRANSCRIPT" 2>/dev/null | jq -rs 'map({type, ts:.timestamp})' 2>/dev/null)
  log_decision "skip" "extraction empty (no assistant text in current turn). transcript_tail: ${TRANSCRIPT_TAIL//$'\n'/ }"
  exit 0
fi

EXTRACTED_TS="${LAST_RECORD%%|||*}"
LAST_BLOCK="${LAST_RECORD#*|||}"

# Diagnostic: timestamp САМОЙ ПОСЛЕДНЕЙ записи в transcript (любого type),
# чтобы видеть race — если она гораздо новее чем EXTRACTED_TS, значит file-write
# опередил наше чтение.
TRANSCRIPT_LAST_TS=$(tail -n 5 "$TRANSCRIPT" 2>/dev/null | jq -rs 'last.timestamp // ""' 2>/dev/null)

# Compute lag в минутах между EXTRACTED_TS и сейчас (для diagnostic logs)
LAG_MINUTES=""
if [[ -n "$EXTRACTED_TS" ]]; then
  # macOS BSD date: -j -f format; Linux: -d
  TS_ISO="${EXTRACTED_TS%.*}"  # strip fractional seconds
  TS_ISO="${TS_ISO%Z}"          # strip Z
  # macOS BSD date интерпретирует input как local time без TZ=UTC.
  # transcript ts всегда UTC (Z), поэтому форсируем TZ=UTC при парсинге.
  TS_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$TS_ISO" "+%s" 2>/dev/null \
            || date -d "$EXTRACTED_TS" "+%s" 2>/dev/null \
            || echo "")
  if [[ -n "$TS_EPOCH" ]]; then
    LAG_MINUTES=$(( ($(date +%s) - TS_EPOCH) / 60 ))
  fi
fi

# CRLF normalize
LAST_BLOCK=$(printf '%s' "$LAST_BLOCK" | tr -d '\r')

# Markdown-strip УДАЛЁН (по решению пользователя):
# Агенты пишут verdict в произвольном форматировании — bold/code/quotes/plain.
# Любая попытка распознать «это пример vs это real verdict» по форматированию даёт
# false-negatives на реальных verdict'ах. Лучше иногда лишний раз сработать на
# meta-обсуждении (bypass решает) чем пропустить настоящий verdict.
# Оставляем только CRLF normalize выше; LAST_BLOCK_STRIPPED = LAST_BLOCK.
LAST_BLOCK_STRIPPED="$LAST_BLOCK"

# Считаем реальные code-edits в текущем турне (после последнего user message).
# Используется для:
#   1. Meta-bypass: magic-string работает только если EDITS_IN_TURN=0 (не было работы → meta legit)
#   2. Missing-verdict trigger: если EDITS_IN_TURN>0 + FDR-context + НЕТ verdict → block "дай verdict"
EDITS_IN_TURN=$(tail -n 200 "$TRANSCRIPT" 2>/dev/null | jq -rs '
  (length - 1 - (reverse | map(.type == "user") | index(true) // length)) as $u
  | .[$u+1:]
  | map(select(.type == "assistant"))
  | map(.message.content // [] | if type == "array" then . else [] end)
  | flatten
  | map(select(.type? == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "MultiEdit")))
  | length
' 2>/dev/null)
EDITS_IN_TURN=${EDITS_IN_TURN:-0}
[[ "$EDITS_IN_TURN" =~ ^[0-9]+$ ]] || EDITS_IN_TURN=0

# Magic-string для self-bypass meta-discussion (см. cycle 0 reason).
# Длинный + специфичный, чтобы случайный match был невозможен.
META_MAGIC='meta-discussion, no FDR work'

# ============================================================================
# CYCLE 0 — начальный челлендж (если ещё не запускался)
# ============================================================================
if [[ "$CYCLE" -eq 0 ]]; then
  # Verdict pattern check
  # Trigger patterns — расширены для покрытия типичных перефразировок:
  #   1. "0 проблем" / "0 [critical] findings" / "0 issues" — числовые «нет»-вердикты
  #   2. "ready to merge" / "verdict: ready/clean/0 X" — формальные verdict-фразы
  #   3. "no X found" — отрицательные verdict
  #   4. "found nothing" / "нашёл ничего" — RU/EN устные
  #   5. "all clean" / "всё чисто" — informal allclear
  #   6. "выглядит хорошо/отлично/чисто" — RU informal
  #   7. "nothing to fix/address" / "none critical" — bypass-перефразировки
  #   8. "N findings closed/resolved/fixed" — декларация закрытия findings
  #   9. "all/всё findings closed/resolved" — глобальное закрытие
  #  10. "verdict/итог: complete/done/готов/завершен" — статус-словарь
  #  11. "FDR=0" / "FDR: 0" — компактные форматы
  # Capture matched fragment для observability (logged как `matched: <fragment>`)
  MATCHED_PATTERN=$(printf '%s' "$LAST_BLOCK_STRIPPED" | grep -oiE '(0[[:space:]]*проблем|0[[:space:]]+([[:alpha:]]+[[:space:]]+)?(issues?|problems?|findings?)|ready[[:space:]]+to[[:space:]]+merge|verdict[^.]*(ready|clean|0[[:space:]]+(open|problems|проблем))|no[[:space:]]+(issues|findings|problems)[[:space:]]+found|(found|нашёл)[[:space:]]+(nothing|ничего)|(all|всё)[[:space:]]+(clean|clear|ok|чисто)|выглядит[[:space:]]+(хорошо|отлично|чисто|нормально)|(nothing|none)[[:space:]]+(to[[:space:]]+(fix|address)|critical)|[0-9]+[[:space:]]+(findings?|issues?|problems?|замечани[йя])[[:space:]]+(closed|resolved|fixed|устранен|закрыт|исправлен)|(all|всё|все|every)[[:space:]]+(findings?|issues?|problems?|замечани[йя])[[:space:]]+(closed|resolved|fixed|закрыт|устранен)|(everything|всё)[[:space:]]+(closed|resolved|fixed|done|completed|устранен|исправлен|закрыт)|(verdict|итог|status)[^.]{0,40}(complete|completed|done|finished|закончен|завершен)|(FDR|ФДР|review|ревью)[[:space:]]*[=:][[:space:]]*0\b)' 2>/dev/null | head -1)
  # Truncate matched pattern для лога (если очень длинный)
  [[ -n "$MATCHED_PATTERN" ]] && MATCHED_PATTERN="${MATCHED_PATTERN:0:100}"

  # FDR context narrowing — нужен ДО ветвления (используется и для verdict-flow и для missing-verdict).
  CONTEXT=$(tail -n 200 "$TRANSCRIPT" 2>/dev/null | jq -rs '
    map(.message.content // .text // empty
      | if type == "array" then map(select(.type? == "text") | .text? // "") | join(" ") else tostring end)
    | join(" ")
  ' 2>/dev/null)
  HAS_FDR_CONTEXT=false
  if printf '%s' "$CONTEXT" | grep -qiE '(ФДР|FDR|ревью|review|9[[:space:]]+(layers|слоёв)|/fdr)'; then
    HAS_FDR_CONTEXT=true
  fi

  # ----- Branch 1: verdict-pattern matched -----
  if [[ -n "$MATCHED_PATTERN" ]]; then
    # Meta-bypass: magic-string + НЕТ edits в текущем турне → агент сам объявил meta.
    # Edits есть → magic-string игнорируется (модель пыталась сбежать после реальной работы).
    # F4: length-check — magic-string должна быть в коротком ответе (≤ 300 chars), иначе
    # это цитата спеки/reminder в составе длинного сообщения, а не legit self-bypass.
    LAST_BLOCK_LEN=$(printf '%s' "$LAST_BLOCK" | wc -c | tr -d ' ')
    if [[ "$EDITS_IN_TURN" -eq 0 ]] \
       && [[ "${LAST_BLOCK_LEN:-9999}" -le 300 ]] \
       && printf '%s' "$LAST_BLOCK" | grep -qF "$META_MAGIC"; then
      log_decision "allow-self-meta" "magic-string present, edits_in_turn=0, len=$LAST_BLOCK_LEN"
      exit 0
    fi

    if ! $HAS_FDR_CONTEXT; then
      log_decision "skip" "verdict matched but no FDR-context in last 200 transcript lines"
      exit 0
    fi

    # Hash-tracking — не re-fire на тот же verdict-text повторно (stale lookback).
    # Префикс "v:" разделяет namespace verdict-trigger и missing-verdict trigger
    # (один финальный текст может теоретически зафайрить разные триггеры в разных турнах).
    HASH="v:$(printf '%s' "$LAST_BLOCK" | shasum -a 256 2>/dev/null | cut -d' ' -f1 | cut -c1-16)"
    if [[ "$HASH" != "v:" && -f "$HASHES_FILE" ]] && grep -qF "$HASH" "$HASHES_FILE" 2>/dev/null; then
      log_decision "skip" "stale verdict, hash=$HASH already fired"
      exit 0
    fi
    [[ "$HASH" != "v:" ]] && echo "$HASH" >> "$HASHES_FILE" 2>/dev/null || true
    # Provoke standard verdict challenge flow (continues below).
  else
    # ----- Branch 2: НЕТ verdict-pattern -----
    # Missing-verdict trigger: были code edits в турне + есть FDR-context, но финальное
    # сообщение не содержит verdict-фразы → агент пытается убежать «отчитался и ушёл».
    if [[ "$EDITS_IN_TURN" -gt 0 ]] && $HAS_FDR_CONTEXT; then
      # Hash-tracking — префикс "m:" отделяет от verdict-trigger namespace (см. выше).
      HASH="m:$(printf '%s' "$LAST_BLOCK" | shasum -a 256 2>/dev/null | cut -d' ' -f1 | cut -c1-16)"
      if [[ "$HASH" != "m:" && -f "$HASHES_FILE" ]] && grep -qF "$HASH" "$HASHES_FILE" 2>/dev/null; then
        log_decision "skip" "missing-verdict, hash=$HASH already fired"
        exit 0
      fi
      [[ "$HASH" != "m:" ]] && echo "$HASH" >> "$HASHES_FILE" 2>/dev/null || true

      # F3: classification="initial" (известный judge'у тип) + trigger в summary для аудита.
      printf '{"cycle":0,"classification":"initial","summary":"missing-verdict trigger: edits=%s, no verdict pattern"}\n' \
        "$EDITS_IN_TURN" >> "$HISTORY_FILE" 2>/dev/null || true

      MV_REASON=$'FDR verdict missing: ты делал правки в текущем турне, но финальное сообщение не содержит verdict.\n\n'
      MV_REASON+=$'Дай явный verdict в одном из форматов:\n'
      MV_REASON+=$'  - "0 проблем" — если re-FDR показал чисто\n'
      MV_REASON+=$'  - список open findings (file:symbol + severity) — если ещё есть что фиксить\n\n'
      MV_REASON+=$'Без verdict завершить турн нельзя — это уход без отчёта.\n\n'
      MV_REASON+="Bypass: echo \"<reason>\" > $BYPASS_FILE"

      log_decision "block-missing-verdict" "edits_in_turn=$EDITS_IN_TURN, no verdict pattern"
      jq -n --arg r "$MV_REASON" '{decision:"block", reason:$r}'
      exit 0
    fi
    log_decision "skip" "no verdict pattern in extracted text"
    exit 0
  fi

  # Записать cycle 0 entry (initial challenge)
  printf '{"cycle":0,"classification":"initial","summary":"Initial challenge fired"}\n' \
    >> "$HISTORY_FILE" 2>/dev/null || true

  REASON=$'FDR honesty check: ты заявил verdict, но FDR не доведён.\n\n'
  REASON+=$'Продолжай цикл develop→FDR→fix: найди следующий слой/файл который ещё не прошёл честно, прогони ФДР по нему, найденное — фикси кодом сразу.\n\n'
  REASON+=$'Без таблиц-отчётов в чат — только реальные правки + краткий статус «фикшу X».\n\n'
  REASON+=$'Self-bypass для meta: если triggering фраза была частью обсуждения хука/спеки/meta-вопроса (без реальных правок в этом турне) — ответь КОРОТКО (≤300 символов) с фразой "meta-discussion, no FDR work" и следующий Stop пропустит.\n\n'
  REASON+="Hard bypass (одноразово): echo \"<reason>\" > $BYPASS_FILE"

  log_decision "block-initial" "verdict-pattern detected, FDR context confirmed"
  jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
  exit 0
fi

# ============================================================================
# CYCLE N (N > 0) — judge классифицирует ответ
# ============================================================================

# Meta-bypass на cycle N: если агент в ответ на challenge заявил magic-string
# И в текущем турне нет реальных правок — закрываем цикл (это был meta false-positive).
# F4: length-check тот же что в cycle 0 — short-message-only.
LAST_BLOCK_LEN_N=$(printf '%s' "$LAST_BLOCK" | wc -c | tr -d ' ')
if [[ "$EDITS_IN_TURN" -eq 0 ]] \
   && [[ "${LAST_BLOCK_LEN_N:-9999}" -le 300 ]] \
   && printf '%s' "$LAST_BLOCK" | grep -qF "$META_MAGIC"; then
  rm -f "$HISTORY_FILE" 2>/dev/null || true
  log_decision "allow-self-meta" "magic-string in cycle $CYCLE response, edits_in_turn=0, len=$LAST_BLOCK_LEN_N"
  exit 0
fi

# Если judge отключён — fallback к старому one-shot (cycle 0 уже сработал, allow)
if [[ "${STRICT_NO_HAIKU_JUDGE:-0}" = "1" ]]; then
  rm -f "$HISTORY_FILE" 2>/dev/null || true
  log_decision "allow" "judge disabled by env, one-shot fallback"
  exit 0
fi

# Подготовить вход для judge
HISTORY_JSON=$(jq -s '.' < "$HISTORY_FILE" 2>/dev/null)
[[ -z "$HISTORY_JSON" ]] && HISTORY_JSON="[]"

JUDGE_INPUT=$(jq -n \
  --argjson h "$HISTORY_JSON" \
  --arg c "$LAST_BLOCK" \
  '{history: $h, current_response: $c}')

JUDGE_OUTPUT=$(printf '%s' "$JUDGE_INPUT" | "$HOME/.claude/hooks/judge.sh" 2>/dev/null)

CLASSIFICATION=$(printf '%s' "$JUDGE_OUTPUT" | jq -r '.classification // "unknown"' 2>/dev/null)
GAPS=$(printf '%s' "$JUDGE_OUTPUT" | jq -r '.gaps_to_demand // [] | join(", ")' 2>/dev/null)
RATIONALE=$(printf '%s' "$JUDGE_OUTPUT" | jq -r '.rationale // ""' 2>/dev/null)

# Записать текущий cycle entry
SUMMARY=$(printf '%s' "$LAST_BLOCK_STRIPPED" | head -c 300 | tr '\n' ' ' | sed 's/"/\\"/g')
printf '{"cycle":%s,"classification":"%s","summary":"%s","gaps":"%s"}\n' \
  "$CYCLE" "$CLASSIFICATION" "$SUMMARY" "$GAPS" \
  >> "$HISTORY_FILE" 2>/dev/null || true

# Подсчёт ТРЕЙЛИНГ повторов (сколько последних entries имеют classification=repetitive).
# tac нет на macOS, поэтому делаем одним awk-проходом без реверса:
# счётчик растёт на repetitive, сбрасывается на любом другом, в конце выводит трейлинг.
REPETITION_COUNT=$(awk '
  /"classification":"repetitive"/ { rep++; next }
  { rep = 0 }
  END { print rep+0 }
' "$HISTORY_FILE" 2>/dev/null)
REPETITION_COUNT=${REPETITION_COUNT:-0}
# Sanitize: только цифры
REPETITION_COUNT=${REPETITION_COUNT//[^0-9]/}
REPETITION_COUNT=${REPETITION_COUNT:-0}

case "$CLASSIFICATION" in
  complete)
    rm -f "$HISTORY_FILE" 2>/dev/null || true
    log_decision "allow" "judge=complete: $RATIONALE"
    exit 0
    ;;
  substantive)
    # P2 anti-stall: если judge возвращает substantive с теми же gaps что в предыдущем
    # цикле — модель не может улучшить, snowballing бесполезен. Выходим с warning.
    LAST_2_SAME=$(tail -n 2 "$HISTORY_FILE" 2>/dev/null | jq -rs '
      if length < 2 then "no" else
        (if (.[0].gaps // "") == (.[1].gaps // "") and ((.[0].gaps // "") | length) > 0
         then "yes" else "no" end)
      end' 2>/dev/null)
    if [[ "$LAST_2_SAME" = "yes" ]]; then
      rm -f "$HISTORY_FILE" 2>/dev/null || true
      log_decision "allow" "stalled: judge demands same gaps repeatedly, model cannot improve"
      exit 0
    fi
    REASON=$"FDR cycle $CYCLE: judge нашёл новые findings — фикси их кодом, потом продолжай ФДР по оставшимся слоям. Не отчитывайся таблицами — правь.\n\nJudge rationale: $RATIONALE"
    [[ -n "$GAPS" && "$GAPS" != "" ]] && REASON+=$"\n\nКонкретно: $GAPS"
    REASON+=$"\n\nBypass: echo \"<reason>\" > $BYPASS_FILE"
    log_decision "block-substantive" "$RATIONALE"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    exit 0
    ;;
  evasive)
    REASON=$"FDR cycle $CYCLE: ответ общий, ФДР не двигается. Открой конкретные файлы, найди реальные проблемы, фикси кодом. Не объясняй план — делай."
    [[ -n "$GAPS" && "$GAPS" != "" ]] && REASON+=$"\n\nКонкретно: $GAPS"
    REASON+=$"\n\nBypass: echo \"<reason>\" > $BYPASS_FILE"
    log_decision "block-evasive" "$RATIONALE"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    exit 0
    ;;
  repetitive)
    if [[ "${REPETITION_COUNT:-0}" -ge 2 ]]; then
      rm -f "$HISTORY_FILE" 2>/dev/null || true
      log_decision "allow" "judge=repetitive x$REPETITION_COUNT, stopping cycle"
      exit 0
    fi
    REASON=$"FDR cycle $CYCLE: judge says you are repeating prior findings. Either add NEW substantive findings OR finalize the verdict explicitly.\n\nJudge rationale: $RATIONALE"
    REASON+=$"\n\nBypass: echo \"<reason>\" > $BYPASS_FILE"
    log_decision "block-repetitive" "$RATIONALE (count=$REPETITION_COUNT)"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    exit 0
    ;;
  unknown|*)
    rm -f "$HISTORY_FILE" 2>/dev/null || true
    log_decision "allow" "judge unknown/unavailable: $RATIONALE"
    exit 0
    ;;
esac
