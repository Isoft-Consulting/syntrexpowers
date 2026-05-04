# Claude Code Strict Mode

Hook-расширения для Claude Code которые **механически принуждают** агента доводить код до рабочего состояния, проводить честный FDR (Full Deep Review) и тратить меньше токенов. Без надежды на «дисциплину модели» — все правила enforced'ятся через harness.

---

## Состав релиза

Три развёрнутые волны (Wave 1 + 2 + 2.5) — все active. Wave 3 запроектирован в спеке но НЕ реализован.

| Wave | Что делает | Статус |
|------|-----------|--------|
| **Wave 1** | Token economy: компактный `CLAUDE.md` (EN + RU output policy), `prune-mem.py` для подрезки `claude-mem-context` блоков | ✅ active |
| **Wave 2** | Hook-каркас: stub-detection (PHP/Go/JS/TS/Python), prompt-injection каждый turn, stop-guard на стабы, edits-log, health-check на старте сессии | ✅ active |
| **Wave 2.5** | FDR honesty challenge с Haiku-judge: ловит verdict-фразы, классифицирует ответ агента, требует продолжения если evasive/substantive | ✅ active |
| **Wave 3** | Артефакт-гейт, `/fdr` skill, multi-agent FDR-runner, static prepass, sensitive-paths verifier | 📋 spec only |

> ⚠️ **Wave 3 не входит в bundle.** Документация в `docs/claude-code-strict-mode-v1.md` описывает дизайн. `install.sh --enable-wave3` только добавит permissions, но кода скилла нет.

---

## Полный список фич

### Wave 1 — Token Economy

- **Slim `~/.claude/CLAUDE.md`** на английском с RU output policy в первой строке. −2..3k токенов на каждом турне.
- **`prune-mem.py`** — подрезает `<claude-mem-context>` блок до 7 дней / 5 записей в день. −3..7k токенов на турн.
- **Бекапы** перед каждой подрезкой в `~/.claude/state/mem-backup-<ISO>.md` (ротация 7 шт).
- **Защита от corrupting** — на ошибке парсинга маркеров exit без записи + лог в `prune-errors.log`.
- **Cron weekly** запуск (опционально).

### Wave 2 — Foundation Hooks

**Stub-detection at write-time** (`pre-write-scan.sh` в `PreToolUse(Write|Edit|MultiEdit)`):
- Universal: `// TODO`, `// FIXME`, `// XXX`, `// HACK`
- PHP: `throw new Exception("not implemented")`, `die("stub")`
- Go: `panic("not implemented")`, `// TODO(...)`
- JS/TS: `throw new Error("TODO")`
- Russian markers: `дореал`, `доделат`, `допиш`, `реализую позже`, `placeholder`
- Skip при content > 512KB (env `STRICT_PRE_WRITE_MAX_BYTES`) — защита от больших generated files

**Per-line bypass:** добавить `// allow-stub: <reason>` к строке.

**Stub re-scan at Stop** (`stop-guard.sh`):
- Сканирует все session-edited файлы (из `edits-<sid>.log`) — если стаб остался, block с listingом.
- Subagent edits попадают в parent log через `parent_session_id`.
- Идемпотентен — безопасно при отсутствии fdr-validate.sh / fdr-verify.sh (Wave 3 phase guards).

**Edits log** (`record-edit.sh` в `PostToolUse(Write|Edit|MultiEdit)`):
- Пишет абсолютные пути правок в `~/.claude/state/edits-<sid>.log`.
- Subagent → parent log через `CLAUDE_PARENT_SESSION_ID` env или `parent_session_id` JSON field.
- Orphan-fallback: subagent без parent_sid → `orphan-edits.log` (агрегация parent'ом по timestamp).
- Всегда exit 0 (PostToolUse не ломает tool result).

**Strict-mode reminder** (`prompt-inject.sh` в `UserPromptSubmit`):
- 7 правил инжектятся в context каждого турна (≤120 токенов).
- Включает: no stubs, mandatory FDR thinking, verdict-with-rationale, meta-bypass инструкция.

**Health-check at SessionStart** (`health-check.sh`):
- Проверяет deps: `jq, git, python3, awk, gtimeout`.
- Размер `CLAUDE.md` (warn если > 16KB).
- Создаёт `~/.claude/state/`.
- Создаёт `session-start-<sid>` timestamp файл (для orphan-edits aggregation).

**Per-project disable:** `<project>/.claude/strict-mode.disabled` — все хуки skip в этом проекте.

**Hard bypass (одноразовый):** `~/.claude/state/bypass-<sid>` файл с reason — auto-delete после Stop, append в `bypass-log.jsonl` для аудита.

**Stale-state auto-reset:** history файлы старше 30 минут считаются зависшими, сбрасываются автоматически.

### Wave 2.5 — Honesty Challenge

**Verdict-pattern detection** в финальном assistant message — 11 классов фраз:
1. `0 проблем` / `0 issues` / `0 problems` / `0 critical findings`
2. `ready to merge`
3. `verdict: ready/clean/0 X`
4. `no issues/findings/problems found`
5. `found nothing` / `нашёл ничего`
6. `all/всё clean/clear/ok/чисто`
7. `выглядит хорошо/отлично/чисто/нормально`
8. `nothing to fix/address` / `none critical`
9. `N findings closed/resolved/fixed/устранен/закрыт`
10. `verdict/итог/status: complete/done/готов/завершен`
11. `FDR=0` / `ФДР: 0`

**FDR-context narrowing** — pattern-fire только если в последних 200 строках транскрипта есть маркеры `ФДР|FDR|ревью|review|9 layers|/fdr`. Защищает от random «0 проблем» в meta-разговоре.

**Hash-tracking** против stale lookback — один verdict text может зафайрить challenge только один раз. Namespace разделение: `v:` (verdict-trigger) и `m:` (missing-verdict) — чтобы один и тот же текст потенциально мог запустить разные триггеры.

**Multi-cycle с Haiku-судьёй** (`judge.sh`):
- Cycle 0: initial challenge при verdict-pattern в FDR-context.
- Cycle N: ответ агента классифицируется через `claude -p --model claude-haiku-4-5-20251001`:
  - `complete` — list of findings ИЛИ `0 проблем` + 1-3 sentence rationale → allow Stop
  - `substantive` — новые findings vs history → block с «фикси кодом и продолжай»
  - `evasive` — общие слова без file:symbol → block с requirement specifics
  - `repetitive` — повтор предыдущих findings → cap-stop после 2 в ряд
  - `unknown` — judge unavailable → fallback allow с warning
- **Anti-stall:** judge demands те же gaps 2 раза подряд → allow с warning «model cannot improve».
- **Failsafe cap:** 10 циклов максимум.

**Subagent skip** — `SubagentStop` event и `/subagents/` path в transcript_path не файрят (bundle-agents не получают свой challenge).

**Read-delay 2000ms** против race condition transcript-write vs hook-read. Override через `STRICT_HOOK_READ_DELAY_MS=N`.

**Current-turn extraction** через jq — берётся только последний non-empty assistant text после последнего user message. Защищает от lookback в старые турны.

### Wave 2.5+ enhancements (deployed 2026-05-03)

- **No-tables policy** — cycle reason'ы переписаны на императивы «продолжай develop→FDR→fix», без требования 9-layer таблицы coverage. Reminder #2: «9 FDR layers internally — NO 9-layer coverage table in chat».

- **Self-bypass через magic-string** — агент может ответить буквально `meta-discussion, no FDR work` (≤300 chars) → хук пропускает Stop. Защиты:
  - Работает только если `EDITS_IN_TURN==0` (нет реальных правок в текущем турне через jq-счётчик `tool_use` Edit/Write/MultiEdit).
  - Length-check ≤300 chars отсекает цитаты в длинных сообщениях.
  - Логируется как `allow-self-meta`.

- **Missing-verdict trigger** — если в текущем турне БЫЛИ ЛЮБЫЕ edits (code, docs, configs, migrations, README, спеки) AND есть FDR-context, но финальное сообщение НЕ содержит verdict-фразы → block с reason «дай verdict (`0 проблем`+rationale OR list of findings)». Закрывает «отчитался про round-N fixes и убежал без verdict». Docs не освобождают от ФДР — они часто содержат incorrectness в инструкциях, противоречиях между разделами, неточных number/path claims.

- **Verdict-with-rationale requirement** — judge prompt требует rationale для `0 проблем` (1-3 sentences naming concrete checked items). Bare verdict классифицируется как `evasive`.

- **Recursion guard (CRITICAL)** — env-флаг `STRICT_MODE_NESTED=1` экспортируется при `claude -p` вызове из judge.sh. ВСЕ 6 хуков (`prompt-inject`, `fdr-challenge`, `stop-guard`, `health-check`, `pre-write-scan`, `record-edit`) skip при флаге. Без этого Haiku-судья получал свой strict-mode reminder и реагировал бы как обычный агент.

- **Judge prompt syntax fix (CRITICAL)** — старый `PROMPT="..."` в judge.sh содержал литералы с двойными кавычками внутри двойных и `weren't` (одинарный апостроф) → bash интерпретировал как command + unmatched quote → judge не вызывался ВООБЩЕ. Все «judge unknown» в логах ДО фикса — последствие этого. Решено через quoted heredoc + placeholder substitution.

- **MCP/tools isolation для headless judge** — `--strict-mcp-config --tools "" --` отключают MCP-серверы и built-in tools при вызове `claude -p`. Без этого один пользовательский MCP-плагин с невалидной schema (`oneOf/allOf/anyOf` at top level) ломал API call с 400 error → judge никогда не работал.

- **Diagnostic logging** — `judge.sh` дампит stderr+stdout+prompt-size в `~/.claude/state/judge-stderr.log` при exit≠0 для последующего анализа. `fdr-challenge.sh` пишет в `stop-guard.log` extra-поля: `matched`, `extracted_from_ts`, `lag_minutes`, `transcript_last_ts` (race-detection).

- **gtimeout dependency** — `brew install coreutils` обязателен на macOS. Без него `claude -p` без timeout-обёртки может зависнуть. judge timeout 50s (10s buffer ниже Stop hook timeout 60000ms).

- **Hash namespace separation** (`v:`/`m:`) — verdict-trigger и missing-verdict не делят хеш-кэш.

### Wave 3 Phase 2 — Core enforcement (deployed 2026-05-04)

Foundation для full Wave 3. Включает три компонента поверх Wave 2.5:

**`is-trivial-diff.sh`** — определяет можно ли пропустить ФДР для текущего git diff:
- Tracked + untracked файлы (через `git ls-files --others --exclude-standard`).
- Skip классы: whitespace-only, comments-only (PHP/Go/JS/TS/Python/Ruby/sh), lockfiles (composer/package/cargo/poetry/etc), translations (lang/i18n/locales).
- Sensitive-paths overrides skip (auth/payment/migrations всегда триггерят ФДР).
- **Docs (`*.md`/`*.rst`/`*.txt`/README/CHANGELOG) НЕ skip** — они часто содержат incorrectness в инструкциях, противоречиях, number-discrepancies. Триггерят ФДР через missing-verdict.
- Exit codes: 0=trivial / 1=not trivial (FDR mandatory) / 1=not git repo (treated as non-trivial).

**`fdr-validate.sh`** — артефакт-валидатор по схеме spec §4.2.1, 11 проверок:
- C1 артефакт существует + не пустой
- C2 каждый файл из edits-log в `## Scope` блоке
- C3 каждый Finding имеет 7 полей (file/layer/scenario/expected/actual/severity/status); CRITICAL/HIGH ОБЯЗАТЕЛЬНО `:line` в file
- C4 severity ∈ {CRITICAL, HIGH, MEDIUM, LOW}
- C5 status ∈ {open, resolved, reopened, partial}
- C6 Verdict 2-line format (`status: ...` + `counts: N open / M resolved`) + open-vs-complete consistency
- C7 cycles ≥ 2 если findings были и все resolved
- C8 запрещённые секции/фразы (Persistent Review Rule)
- C9 `## Layer 0` секция если Phase 4 (static-prepass) активен
- C10 status:resolved требует `fix-commit: <sha|pending>` + `re-check: <ISO> — <verifier>`
- C11 bypass-файл (`~/.claude/state/bypass-<sid>`) пропускает валидацию (одноразово, логируется)

**`stop-guard.sh` extended** — поверх Wave 2 stub-scan добавляет 4 проверки:
- (a) edits-log непустой + НЕТ артефакта + не trivial-diff → block «FDR artifact missing»
- (b) артефакт есть → run validator → пробросить C-fail messages в reason
- (c) артефакт + open findings + `mtime(edits-log) > mtime(artifact)` → block «invoke /fdr to recheck»
- (d) sensitive-paths detected → run `fdr-verify.sh` (Phase 5 hook, no-op без verifier executable)

Все 4 idempotent через `[[ -x ]]` guards. Decision aggregation: множественные block reasons combine с `\n---\n` separator.

**⚠️ КРИТИЧНО: `STRICT_NO_ARTIFACT_GATE=1` для Phase 2-only deploy**

Phase 2 без Phase 3 (`/fdr` skill) **сломает workflow** — нет способа сгенерировать `fdr-<sid>.md`, и проверки (a) и (c) заблокируют каждый Stop с edits навсегда. Решение — env-флаг отключает (a) и (c):

```bash
# В ~/.zshrc или ~/.bash_profile (постоянно):
export STRICT_NO_ARTIFACT_GATE=1

# Или для одной сессии:
STRICT_NO_ARTIFACT_GATE=1 claude
```

Это оставляет Wave 2.5 (challenge на verdict-pattern) полностью рабочим + добавляет Wave 3 (b) валидатор для случаев когда артефакт уже есть. После deploy Phase 3 (когда `/fdr` skill сможет генерировать артефакт) — снять флаг.

**Тесты Phase 2:** 30 новых (W4.1-W4.22 для is-trivial-diff + fdr-validate, W5.1-W5.9 для stop-guard extensions, W5.7b для transitional flag). Combined block test (stub + invalid artifact в одном Stop chain) проверяет decision aggregation.

---

## Установка

**Требования:**
- macOS или Linux
- `bash`, `jq`, `git`, `python3`, `awk`
- На macOS обязательно `brew install coreutils` для `gtimeout` (иначе judge может зависать)
- Активная Claude Code сессия с Anthropic auth (для headless judge через Haiku)

```bash
# Из этой папки:
bash install.sh
```

Что произойдёт:
1. Backup существующих `~/.claude/{CLAUDE.md, settings.json, sensitive-paths.txt, stub-allowlist.txt}` в `~/.claude/backups/<file>.bak-<timestamp>`.
2. Создаст `~/.claude/{hooks,state,specs,backups}/`.
3. Скопирует все hook-скрипты (9 штук) в `~/.claude/hooks/`.
4. Установит `~/.claude/sensitive-paths.txt` и `~/.claude/stub-allowlist.txt` (если ещё нет).
5. Скопирует spec в `~/.claude/specs/claude-code-strict-mode-v1.md`.
6. Если `~/.claude/CLAUDE.md` НЕ существует — поставит из template. Если существует — НЕ ТРОНЕТ (покажет инструкцию).
7. Мерджит `hooks` block в `~/.claude/settings.json` (без overwrite существующих хуков).
8. Прогонит `tests/run-tests.sh` (149 тестов).

**Идемпотентен:** можно запускать многократно, ничего не сломает.

---

## Активация

Hooks читаются Claude Code на **старте сессии**. После `install.sh`:

```bash
exit              # выйти из текущей Claude Code сессии (если в ней)
claude            # запустить новую — settings + hooks подгрузятся
```

При старте новой сессии может появиться warning от `health-check` если что-то отсутствует.

---

## Использование

**Ничего специально делать не надо** — всё работает автоматически.

**Что увидишь:**
- На каждом сообщении пользователя в context добавляется `[STRICT MODE]` reminder (7 правил).
- При попытке записи кода со стабом → tool call блокируется с подсказкой про per-line `// allow-stub: <reason>`.
- При завершении turn со стабами в session-edited файлах → блок Stop.
- При `0 проблем` / verdict в FDR-контексте → challenge с требованием продолжать develop→FDR→fix цикл.
- При code edits + FDR-context + НЕТ verdict → блок «дай verdict».
- На cycle N: ответ оценивается Haiku → continue/stop по классификации.

---

## Bypass mechanisms

**1. Self-bypass для meta-discussion** (recommended):
```
meta-discussion, no FDR work
```
Просто ответь буквально этой фразой коротким сообщением (≤300 chars). Работает только если в текущем турне НЕТ code edits.

**2. Hard bypass (одноразовый, audited):**
```bash
echo "false-positive: <reason>" > ~/.claude/state/bypass-<SESSION_ID>
```
Path к файлу указан в самом сообщении блока. Файл удаляется после первого Stop. Использование append'ится в `~/.claude/state/bypass-log.jsonl`.

**3. Per-project disable:**
```bash
mkdir -p <project>/.claude
touch <project>/.claude/strict-mode.disabled
```
Все хуки skip в этом проекте. Удалить файл — снова включится.

**4. Per-line bypass для стабов:**
```php
// TODO: temp workaround // allow-stub: tracked in JIRA-1234
```

---

## Maintenance

**Раз в неделю** подрезай `claude-mem-context` (если используешь claude-mem plugin):

```bash
python3 ~/.claude/hooks/prune-mem.py ~/.claude/CLAUDE.md
python3 ~/.claude/hooks/prune-mem.py ~/PROJECT/CLAUDE.md   # если есть проектный
```

**Регрессионная проверка хуков** после правок:

```bash
bash ~/.claude/hooks/tests/run-tests.sh
```

Должно быть `PASSED: 149, FAILED: 0`.

**Журнал блокировок:**

```bash
tail -50 ~/.claude/state/stop-guard.log    # decisions хуков
tail -20 ~/.claude/state/bypass-log.jsonl  # использованные bypass'ы
tail -20 ~/.claude/state/judge-stderr.log  # judge fails (если были)
```

---

## Troubleshooting

**Хук не срабатывает на verdict в новой сессии:**
- `settings.json` читается на старте сессии. Если изменения после старта — restart сессии.
- Stale `~/.claude/state/fdr-cycles-<sid>.jsonl` от предыдущей зависшей сессии: `rm ~/.claude/state/fdr-cycles-*.jsonl`.
- Проверь что в проекте нет `.claude/strict-mode.disabled`.

**Хук файрит false-positive слишком часто:**
- Self-bypass через magic-string (см. выше) — самый быстрый способ.
- Hard bypass через `bypass-<sid>` файл.
- Per-project disable.
- Если конкретный паттерн ложно срабатывает в твоей доменной речи — открой issue, расширим guard'ы.

**Judge unknown / cycle 1 allow в логах:**
- Означает `claude -p` (haiku) вернул error. Hook fail-safe'но allows. На следующем verdict снова попробует.
- **Точная диагностика** в `~/.claude/state/judge-stderr.log`: stderr+stdout+prompt size при каждом fail.
- Частые причины:
  - macOS без `brew install coreutils` → нет `gtimeout` → claude может висеть.
  - MCP plugin с невалидной schema → 400 API error. С версии 2026-05-03 фикшено через `--strict-mcp-config --tools ""`.
  - OAuth/auth expired → `claude /login`.

**Tests fail:**
- Проверь deps: `command -v jq git python3 awk gtimeout`.
- Запусти `bash ~/.claude/hooks/health-check.sh < /dev/null` для warning'ов.
- Если падает только новый W3 тест — `bash -n ~/.claude/hooks/judge.sh` проверит синтаксис.

**Хук «ел» сообщение и пропустил Verdict:**
- В `~/.claude/state/stop-guard.log` ищи запись с этим SID и timestamp.
- Если `cycle=0 skip "no verdict pattern"` — реально не нашёл паттерн (проверь точную формулировку).
- Если `cycle=0 skip "no FDR-context"` — в последних 200 строках транскрипта нет ФДР-маркеров.
- Если `cycle=0 skip "stale verdict, hash already fired"` — этот же текст уже файрил challenge раньше в этой сессии.
- Если ничего нет — хук возможно не запускался (старая сессия до hooks install / per-project disable).

---

## Откат

```bash
bash uninstall.sh
```
Удалит наши хуки из `settings.json` (другие хуки не трогает). Скрипты и `CLAUDE.md` оставит — можно переустановить.

Полный wipe — см. вывод `uninstall.sh`.

---

## Ограничения и не-цели

- **Не делает модель умнее.** Семантическую глубину ревью паттерны не вытащат.
- **Формально-полный, но поверхностный FDR не ловится** — challenge требует наличия rationale, но не качества проверки. Wave 3 (артефакт-гейт + multi-agent reviewer) это закроет.
- **Стабы без ключевых слов** (пустое тело функции) не детектируются — false-positives на TS interface / PHP abstract / Go spec слишком дорогие.
- **На субагентах эффект слабее** — они получают свой контекст, `UserPromptSubmit` инжект не достигает их напрямую (но stub-detection работает).
- **Headless judge зависит от Anthropic API** — если auth expired или rate-limited, `claude -p` fails → fallback `unknown` → silent allow. Diagnostic в judge-stderr.log.

---

## Спека

Полная design-документация (16 разделов, 7-уровневая декомпозиция, 25+ findings закрытых FDR-циклами, Wave 2.5+ enhancements section, рекомендации по Wave 3): `~/.claude/specs/claude-code-strict-mode-v1.md` (после установки) или `docs/claude-code-strict-mode-v1.md` (в этом bundle).

---

## Структура bundle

```
strict-mode-bundle/
├── README.md                  # этот файл
├── install.sh                 # установщик (идемпотентный)
├── uninstall.sh               # откат
├── hooks/
│   ├── health-check.sh        # SessionStart: deps check + state init
│   ├── prompt-inject.sh       # UserPromptSubmit: 7-rule STRICT MODE reminder
│   ├── pre-write-scan.sh      # PreToolUse Write/Edit/MultiEdit: block stubs at write-time
│   ├── record-edit.sh         # PostToolUse Write/Edit/MultiEdit: log edits
│   ├── stop-guard.sh          # Stop: re-scan stubs in session-edited files
│   ├── stub-scan.sh           # helper: pattern-based stub detector (PHP/Go/JS/TS)
│   ├── fdr-challenge.sh       # Stop: FDR honesty challenge с verdict/missing-verdict/meta-bypass
│   ├── judge.sh               # helper: Haiku-classifier (--strict-mcp-config --tools "")
│   ├── prune-mem.py           # утилита: подрезка claude-mem-context до 7 дней
│   └── tests/
│       └── run-tests.sh       # 149 unit + integration тестов
├── templates/
│   ├── CLAUDE.md              # universal global rules (EN + RU output policy)
│   ├── sensitive-paths.txt    # generic security paths (auth/payment/migrations/etc)
│   └── stub-allowlist.txt     # пустой шаблон с примерами allow-stub правил
└── docs/
    └── claude-code-strict-mode-v1.md   # full design spec (FDR'd, 16 sections, Wave 2.5+ included)
```

---

## Версия

Bundle deployed: 2026-05-03  
Spec version: v1 + Wave 2.5+ enhancements  
Tests: 149 / 149 pass
