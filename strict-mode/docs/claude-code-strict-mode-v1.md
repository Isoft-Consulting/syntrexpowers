# Claude Code Strict Mode — Спецификация v1

**Статус:** draft
**Дата:** 2026-04-29
**Автор:** Andrey + Claude Opus 4.7
**Назначение:** глобальная (per-machine) конфигурация Claude Code, действующая во всех сессиях и проектах.
**Связанные документы:** `Docs/specs/design-decomposition-framework-v1.md` (фреймворк декомпозиции, Core), `~/.claude/CLAUDE.md`, `~/CLAUDE.md`.

---

## 0. Краткая сводка

Система расширений Claude Code, которая **механически принуждает** Claude доводить код до рабочего состояния, проводить полноценный Full Deep Review (далее — ФДР) и тратить минимум токенов, без необходимости каждый раз напоминать об этом вручную. Реализуется через hooks (`~/.claude/settings.json`), служебные скрипты (`~/.claude/hooks/`), slash-команды (`~/.claude/skills/`) и переработанную языковую стратегию (русский — пользователю, английский — служебно).

Ключевая идея: правило в `CLAUDE.md` модель может «забыть» под нагрузкой. Хук — нет, его исполняет харнесс.

---

## 1. Контекст и цели

### 1.1 Проблема

В долгих сессиях наблюдается:
- Halflife качества: ленивый код, заглушки `TODO`/`FIXME`/`panic("not implemented")`/`throw new Error("not implemented")`.
- Поверхностный ФДР: «9 слоёв чисто, всё ок» без конкретных `file:line`.
- Раздутый расход токенов: чтение файлов целиком, повторные ревью одних и тех же файлов, длинный `claude-mem-context` в `CLAUDE.md`, многословный русский во внутренних служебных текстах.
- Деградация под нагрузкой: правила из `CLAUDE.md` соблюдаются всё хуже по мере роста контекста.

### 1.2 Цели (измеримые)

| # | Цель | Метрика |
|---|------|---------|
| G1 | 0 заглушек в финальном коде сессии | grep на маркеры в diff = 0 |
| G2 | ФДР проводится после ЛЮБЫХ code-edit | артефакт `fdr-<session>.md` присутствует и валиден |
| G3 | Каждая находка ФДР имеет полную форму | `file (+:symbol/:line) / layer / scenario / expected / actual / severity / status` — 7 полей (после C3-релаксации `:line` обязателен только для CRITICAL/HIGH) |
| G4 | Снижение расхода токенов на сессию ≥ 40% | замер до/после на типовых задачах |
| G5 | Системные правила загружаются на каждом турне < 2.5k токенов | замер размера CLAUDE.md + auto-context |
| G6 | Ноль необходимости напоминать «дочисти», «проведи ФДР» вручную | счётчик ручных напоминаний за неделю |

### 1.3 Не-цели

- Не заменяет качество модели и не делает её «глубже».
- Не заменяет CI/CD: статические анализаторы вызываются как pre-pass, но это не полноценный pipeline.
- Не делает семантический анализ — ловятся паттерны, не смысл.
- Не унифицирует все проекты под одну схему — конкретные правила (`AGENTS.md`) проектов остаются авторитетными.

### 1.4 Честные ожидания и ограничения

Прозрачно: что эта система делает и чего не делает.

**Делает:**
- Убирает 70–85% паттерн­ной халтуры: заглушки с маркерами, пропуск ФДР, односторонне недописанные правки.
- Заставляет ФДР иметь правильную форму: scope, findings со всеми полями, verdict.
- Режет токенный расход на 40%+ через diff-only scope, триаж, layer collapse, cache-friendly briefs, языковую оптимизацию, чистку auto-context.

**Не делает:**
- Не делает модель умнее. Семантическую глубину ревью паттерны не вытащат.
- Формально-полный, но поверхностный ФДР не ловится: если все поля заполнены и `Verdict: 0 problems`, валидатор пропустит, даже если проверка была халтурной. Защита — только через independent verifier на sensitive-paths и периодический ручной аудит.
- Стаб без ключевых слов (например, пустое тело функции с осмысленным названием) не детектируется — это сознательный выбор для избежания false positives на интерфейсах TS, абстрактных методах PHP, спеках Go.
- На субагентах эффект слабее: они получают свой контекст, и `UserPromptSubmit`-инжект не достигает их напрямую (только через `SubagentStop` post-fact).
- 100% «всегда и везде» недостижимо: любая LLM деградирует под нагрузкой. Цель — поднять baseline и срезать дешёвую халтуру, а не достичь идеала.

**Критерии неудачи (после 1 месяца эксплуатации):**
- > 5 случаев, когда система пропустила реальную дыру в кодбазе.
- > 1 ложного блока в неделю.
- Снижение скорости разработки > 20% относительно базовой.

В этих случаях параметры/пороги пересматриваются.

---

## 2. 7-уровневая декомпозиция

### Level 7 — Надсистема

Claude Code (CLI/desktop/IDE) как harness, исполняющий LLM-сессии. Доступные точки расширения:

- Hooks API: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `SessionStart`, `Notification`, `PreCompact`. JSON через stdin, exit codes 0/2 для блокировки, JSON-decision для Stop.
- Skills (`~/.claude/skills/`) с slash-команд­ным вызовом.
- `settings.json` иерархия: user → project → local.
- Headless-режим `claude -p "<prompt>"` для запуска изолированных проверок.
- Anthropic API: prompt cache TTL = 5 минут.
- MCP-серверы (например, `inventory-admin`) — внешние tool-провайдеры.
- Платформа: macOS Darwin 24.6, bash, jq, git.

### Level 6 — Миссия

> Гарантировать, что в каждой сессии Claude доводит код до рабочего состояния, проводит глубокий ФДР по ВСЕМ затронутым и связанным файлам, и тратит минимум токенов — без вмешательства пользователя.

### Level 5 — Концепция

**Что это:** набор хук-скриптов, slash-команд, валидаторов и конфигурационных правил, которые механически принуждают определённые паттерны поведения через харнесс.

**Что это НЕ:**
- Не AI-агент над агентом.
- Не семантический ревьюер (это делают LLM-агенты, вызываемые из системы).
- Не CI/CD.
- Не замена `CLAUDE.md` — `CLAUDE.md` остаётся и используется, но дополняется механикой.
- Не проектная конфигурация — это global per-machine. Проектные особенности — в `AGENTS.md` соответствующего проекта.

### Level 4 — Ценности

| # | Ценность | Расшифровка |
|---|----------|-------------|
| V1 | Механика > инструкции | Хук, который блокирует, надёжнее правила в `CLAUDE.md`. |
| V2 | Дешёвое впереди дорогого | Static analyzer перед LLM, триаж перед глубоким ревью, паттерн-чек перед семантикой. |
| V3 | Скоуп = реальные изменения | Diff, а не файл целиком. Релевантные слои ФДР, а не все 9. |
| V4 | Кеш-дружелюбность | Стабильный префикс промптов, переменное в хвосте. Сессия не сидит > 270 сек на одной задаче. |
| V5 | Язык как инструмент токен-экономии | Русский там, где видит человек. Английский там, где видит только модель. |
| V6 | Прозрачность блокировок | Каждое блокирующее срабатывание объясняет, что не так и как починить. |
| V7 | Опционально, но строгий дефолт | Можно отключить per-task или per-project. Дефолт — строгий. |
| V8 | Не ломать `AGENTS.md` проектов | Правила проекта главнее глобальных. |

### Level 3 — Навыки (capabilities)

| # | Навык | Реализация |
|---|-------|-----------|
| S1 | Stub-detection — pre-write блок, post-write журнал, stop-проверка | `pre-write-scan.sh`, `record-edit.sh`, `stop-guard.sh`, `stub-scan.sh` |
| S2 | FDR-enforcement — обязательный артефакт со схемой | `fdr-validate.sh` + Stop hook + `~/.claude/state/fdr-<sid>.md` |
| S3 | FDR-runner — оркестрация триажа + bundle-агентов + diff-recheck | skill `fdr` (`~/.claude/skills/fdr/`) |
| S4 | Independent verifier — selective headless-проверка | `fdr-verify.sh` через `claude -p` |
| S5 | Static-pre-analysis — Layer 0 | `static-prepass.sh`, интегрирует `phpstan`/`staticcheck`/`eslint`/`tsc` |
| S6 | Token economy — diff-only scope, cache-friendly briefs, model routing | встроено в скрипты + конвенции в `CLAUDE.md` |
| S7 | Auto-context hygiene — подрезка `claude-mem-context` и `MEMORY.md` | `prune-mem.py` (cron weekly), `state-cleanup.sh` (cron daily) |
| S8 | Output language routing — RU output, EN internal | переписанный `CLAUDE.md`, EN-промпты в скриптах |
| S9 | Strict-mode prompt injection | `UserPromptSubmit` hook |
| S10 | Sensitive-path detection | `is-sensitive.sh` (regex по путям) |
| S11 | Skip-list для тривиальных правок | `is-trivial-diff.sh` |
| S12 | Environment/dependency health-check на старте сессии | `health-check.sh` (`SessionStart` hook) |
| S13 | State directory cleanup и audit-log ротация | `state-cleanup.sh` (cron daily) |
| S14 | Bypass mechanism (одноразовый, аудируемый) | `~/.claude/state/bypass-<sid>` + `bypass-log.jsonl` |

### Level 2 — Поведение (сценарии)

| # | Сценарий | Что должно произойти |
|---|----------|---------------------|
| B1 | Claude правит PHP с `// TODO: дореализовать` | `PreToolUse` блокирует, stderr объясняет проблему. Claude дописывает полностью. |
| B2 | Правки закончены → Claude хочет завершить турн | `Stop` требует `fdr-<sid>.md`, валидирует схему. Если пусто/невалидно — блок. |
| B3 | Claude вызывает `/fdr` | Триаж на Haiku → выбор слоёв и bundle'ов → 1–4 параллельных агента на Sonnet → артефакт. |
| B4 | Правка в sensitive-path (`auth/`, `wallet/`, `migrations/`, `agent_c/`, `payment/`, `inventory_*`) | После основного ФДР `Stop` запускает headless-верификатор `claude -p`, сравнивает findings. |
| B5 | Правка тривиальная (только comments / только whitespace / только README.md) | `is-trivial-diff.sh` ставит флаг `skip-fdr`, `Stop` пропускает требование артефакта. |
| B6 | Цикл develop → FDR → fix → re-check | Re-check агенту скармливается только diff фикса + список открытых findings, а не полные файлы. |
| B7 | Старт сессии или новый prompt | `UserPromptSubmit` инжектит компактный английский strict-mode reminder. |
| B8 | Раз в неделю | cron-скрипт подрезает `claude-mem-context` старше N дней. |
| B9 | Scope правок > 5 файлов или > 500 строк diff | `Stop` требует декомпозиции на меньшие коммиты, не блокирует — предупреждает с возможностью force через флаг. |
| B10 | Claude хочет вызвать субагента на тривиальной задаче | `PreToolUse` на `Agent` предупреждает, если scope < порога — рекомендует main thread. (Soft warning, не блок.) |

### Level 1 — Окружение

**Файловая структура:**
```
~/.claude/
├── settings.json              # глобальные настройки + hooks
├── CLAUDE.md                  # переписанные правила (EN с RU output policy)
├── hooks/
│   ├── stub-scan.sh           # сканер заглушек (file/stdin режимы)
│   ├── pre-write-scan.sh      # PreToolUse: блок стабов до записи
│   ├── record-edit.sh         # PostToolUse: журнал правок сессии
│   ├── stop-guard.sh          # Stop: проверка стабов + FDR-артефакт + sensitive verify
│   ├── fdr-validate.sh        # валидация схемы fdr-<sid>.md
│   ├── fdr-verify.sh          # headless independent verifier (claude -p)
│   ├── static-prepass.sh      # phpstan/staticcheck/eslint/tsc
│   ├── is-sensitive.sh        # detect sensitive path
│   ├── is-trivial-diff.sh     # detect trivial change
│   ├── prompt-inject.sh       # UserPromptSubmit reminder
│   ├── health-check.sh        # SessionStart: проверка jq/git/timeout/CLAUDE.md size
│   ├── state-cleanup.sh       # cron daily: чистка state/ старше 30 дней
│   └── prune-mem.py           # cron weekly: подрезка claude-mem-context
├── skills/
│   └── fdr/
│       ├── SKILL.md           # описание навыка
│       (тело SKILL.md — инструкция Claude через Agent tool, не shell-скрипт)
├── specs/
│   └── claude-code-strict-mode-v1.md   # этот документ
└── state/                     # runtime, per-session + persistent
    ├── edits-<sid>.log              # список правок сессии (sort -u перед использованием)
    ├── fdr-<sid>.md                 # FDR-артефакт (см. §3.3)
    ├── fdr-verify-<sid>.md          # вывод independent verifier (§4.2.4)
    ├── trivial-flag-<sid>           # ставится is-trivial-diff.sh, разрешает skip
    ├── bypass-<sid>                 # одноразовый bypass (см. F10/Q3)
    ├── prepass-<sid>-<safe-full-path>-<analyzer>.log  # async static-prepass output (§4.3.1) — sanitized full path, не basename
    ├── prepass-<sid>-<safe-full-path>-<analyzer>.log.lock  # active marker — runner ждёт удаления при aggregation (§4.3.1)
    ├── hook-errors-<sid>.log        # неблокирующие ошибки PostToolUse-хуков
    ├── fdr-<sid>.md.tmp             # промежуточный артефакт /fdr skill (атомарный mv в §5.2 step 6)
    ├── runner-error-<sid>.log       # трассировка падений FDR-runner (Q12)
    ├── orphan-edits.log             # subagent-правки без parent_sid (см. Q6 fallback)
    ├── bypass-log.jsonl             # persistent audit log bypass'ов (Q3)
    ├── blocks.jsonl                 # persistent audit log блокировок (Q7)
    ├── prune-errors.log             # ошибки prune-mem.py
    ├── mem-backup-<ISO>.md          # бекапы перед prune-mem (последние 7)
    └── archive/<YYYY>/              # ротация audit-логов > 50 МБ (§4.4.4)
```

**Зависимости:**

| Утилита | Назначение | Установка |
|---------|------------|-----------|
| `bash` ≥ 4 | hooks | системно (macOS даёт 3.2 — нужен brew) |
| `jq` | парсинг stdin JSON в hooks | `brew install jq` |
| `git` | diff, log, blame | системно |
| `timeout` | timeout-обёртка для `claude -p` верификатора | `brew install coreutils` (macOS даёт `gtimeout` — alias) |

**Fail-loud policy:** каждый hook-скрипт на старте проверяет наличие критичных зависимостей и **exit 2** с понятным сообщением, если их нет. Никакого silent bypass:

```bash
for cmd in jq git; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "FATAL: $cmd not installed (required by Claude Code Strict Mode hooks)" >&2
    echo "Install: brew install $cmd" >&2
    exit 2
  }
done
```

Дополнительно — `SessionStart` hook (`health-check.sh`) при старте каждой сессии валидирует окружение и пишет single-line статус в transcript. Если что-то отсутствует — сессия начинается с явным предупреждением модели.


| `phpstan` | PHP static analysis | per-project composer |
| `staticcheck` / `golangci-lint` | Go static analysis | `go install` |
| `eslint` / `tsc` | JS/TS | per-project npm |
| `claude` CLI headless | independent verifier | системно |

**Языки кода целевых проектов:** PHP, Go, JS/TS.

**Sensitive paths (по умолчанию):**
- `*/auth/*`, `*/payment/*`, `*/wallet/*`, `*/security/*`
- `*/migrations/*`, `*.sql`
- `*/agent_c/*`, `/opt/agent_c/*`
- `*/inventory_*`, `inventory-admin/*`
- `*/ZP/*` (зарплатная сверка)
- список расширяемый через `~/.claude/sensitive-paths.txt`

---

## 3. Архитектура

### 3.0 Hook exit-code policy

Унифицированные правила для всех скриптов системы — критично для предсказуемого поведения харнесса:

| Hook | Успех | Блокирующая ошибка | Не-блокирующий warning |
|------|-------|--------------------|-----------------------|
| `PreToolUse` | exit 0 | exit 2 (stderr → модель, инструмент НЕ запускается) | exit 1 (stderr → пользователь, инструмент запускается) |
| `PostToolUse` (`record-edit.sh`, `static-prepass.sh`) | **ВСЕГДА exit 0** | — (ошибки PostToolUse не должны ломать tool result) | exit 1 + лог в `~/.claude/state/hook-errors-<sid>.log` |
| `Stop`, `SubagentStop` | exit 0 (allow) | JSON `{"decision":"block","reason":"..."}` через stdout | exit 1 (warning, не блок) |
| `UserPromptSubmit` | exit 0 (stdout инжектится в context) | exit 2 (блокирует prompt) | exit 1 |
| `SessionStart` | exit 0 | — (не блокирует, только информирует) | stderr → лог |

Все скрипты должны проверять зависимости fail-loud (см. §1 Environment), а не падать тихо.

### 3.1 Поток событий за один турн

```
[user prompt]
  → UserPromptSubmit hook → inject strict-mode reminder (EN, ~80 tokens)
  → model reasoning
    → PreToolUse(Write|Edit|MultiEdit) → pre-write-scan.sh
      ├─ stub detected → exit 2 → BLOCK
      └─ clean → allow
    → tool runs → file written
    → PostToolUse(Write|Edit|MultiEdit) → record-edit.sh → append to edits-<sid>.log
    → PostToolUse(Write|Edit|MultiEdit, *.{php,go,ts,js}) → static-prepass.sh → write Layer-0 to fdr-<sid>.md
  → model continues, eventually wants to stop
  → Stop hook → stop-guard.sh
    1. Scan all session-edited files for stubs (stub-scan.sh)
       → найдено → decision:block, reason includes findings
    2. Check is-trivial-diff
       → trivial → allow stop (skip FDR)
    3. Check fdr-<sid>.md exists and is valid (fdr-validate.sh)
       → invalid → decision:block, reason explains schema
    4. Sensitive-path detection (is-sensitive.sh)
       → yes → run fdr-verify.sh (headless claude -p)
              → verifier finds extra findings → decision:block
    5. Check scope size
       → > 5 files or > 500 lines → soft warning (не блок)
    6. All passed → allow stop, archive artifact
```

### 3.2 Поток ФДР

```
/fdr (slash command, skill body via Agent tool):
  1. Compute scope:
     - edited files from edits-<sid>.log (sort -u)
     - related files via grep imports/usages (depth=1)
  2. Compute diff:
     - git diff for tracked files
     - full file content for untracked
  3. Triage (Haiku 4.5, ~$0.001):
     - input: file list + diffs
     - output JSON: {risk: 1-5, layers: [list of 1-9], bundles: [A|B|C|D]}
  4. Static prepass:
     - run static-prepass.sh on changed files
     - prepend Layer 0 (static) to artifact
  5. Bundle agents (Sonnet 4.6, parallel):
     - Bundle A (1-3): Context, Architecture, Logic
     - Bundle B (4-5): Contracts, Data
     - Bundle C (6-7): Security, Reliability
     - Bundle D (8-9): Performance, Tests/Observability
     Skip bundles not in triage.layers.
     **Mechanism:** skill body использует Claude Code-нативный `Agent` tool с параметром `subagent_type` и параллельным вызовом нескольких Agent'ов в одном message (как требует system prompt: «if you launch multiple agents for independent work, send them in a single message with multiple tool uses»). НЕ через `claude -p` — это были бы новые сессии с холодным кешем и без shared контекста проекта. `claude -p` зарезервирован ИСКЛЮЧИТЕЛЬНО для §4.2.4 independent verifier (там нужна изоляция от parent-контекста, и кеш не критичен).
     Each agent gets:
       - stable prefix (cached): rules, output contract, scope
       - volatile suffix: diff, bundle-specific instruction
  6. Aggregate findings → fdr-<sid>.md
  7. If findings exist:
     - main thread fixes
     - run /fdr-recheck (only diff-of-fix + open findings)
     - cycle until 0 findings or escalation
  8. Verdict written

Sensitive-path verifier (Stop hook, optional):
  9. claude -p with brief, expects compact findings or "0 problems"
  10. Compare to fdr-<sid>.md by file:line
  11. Discrepancies → block stop with diff
```

### 3.3 Артефакт `fdr-<sid>.md` — схема

```markdown
# FDR — session <sid>
generated: <ISO8601>
cycles: 1

## Scope
- file1.php
- file2.go
- migrations/2026_04_x.sql
related:
- helper.php

## Layer 0 (static prepass)
phpstan: 0 errors | staticcheck: 0 issues | eslint: 0

## Findings
### F1
file: app/Service/Wallet.php:142
layer: 6 (security)
scenario: concurrent transfer to same address
expected: row lock + transaction
actual: race condition, double spend
severity: CRITICAL
status: open

### F2
...

## Verdict
status: incomplete
counts: 2 open / 0 resolved
```

**Verdict — ДВЕ строки** канонической формы:
- Строка 1: `status: <complete|incomplete|degraded>` (validator C6 регекс: `^status:\s*(complete|incomplete|degraded)\s*$`)
- Строка 2: `counts: <N> open / <M> resolved` (validator C6b регекс: `^counts:\s*[0-9]+\s+open\s+/\s+[0-9]+\s+resolved\s*$`)

Раздельные строки — потому что проще парсить, не путать с произвольным `|`-разделённым контентом.

После цикла фиксов:
```markdown
cycles: 2

### F1
...
status: resolved
fix-commit: <sha-OR-pending>
re-check: 2026-04-29T14:32 — verified by recheck-agent
```

**`fix-commit` значения:**
- `<sha>` — git SHA коммита фикса (если был commit)
- `pending` — фикс в working tree, ещё не закоммичен (validator C10 принимает оба)

### 3.4 Языковая стратегия (детали)

| Зона | Язык | Обоснование |
|------|------|-------------|
| Финальный ответ пользователю | RU | требование |
| Комментарии в коде | RU | требование, кодовая база |
| Бизнес/доменные термины | RU | непереводимы без потери смысла |
| Сообщения коммитов, PR | RU | команда |
| `AGENTS.md` проектов | RU | команда |
| Спеки (этот документ) | RU | человек читает |
| `~/.claude/CLAUDE.md` системные правила | EN с RU output policy в первой строке | -50% токенов на каждый турн |
| `~/.claude/MEMORY.md` индекс | RU title + EN hook | смешанная читаемость |
| Memory entries (тело) | EN | модель видит, человек редко |
| Промпты субагентам | EN с RU контекстом домена | -50% на бриф, домен сохранён |
| FDR-артефакт | EN compact (`F1 | file:line | SEV | description`) | многоразовое использование, цикл develop→FDR→fix |
| Hooks stderr | EN | компактнее, попадает в контекст модели |
| Slash-команд­ные описания | EN | модель читает чаще, чем человек |
| TaskCreate тела | EN | служебно |

**Защита от перехода ответов на английский:**
1. Первая строка глобального `CLAUDE.md`:
   ```
   Output policy: respond to the user in Russian. Code comments in Russian. Internal artifacts (FDR, briefs, memory bodies, hook stderr) in English. Domain terms in Russian.
   ```
2. `UserPromptSubmit` reminder включает `Reply in Russian.`
3. Промпты субагентов: `Internal output: English. If user-facing summary needed, end with "Резюме на русском: ..." in 1-2 lines.`

---

## 4. Компоненты — детальная спецификация

### 4.1 Stub-detection pipeline (S1)

**Цель:** не дать заглушкам попасть на диск; не дать сессии завершиться, пока не дочищено.

**Маркеры (паттерны):**

| Класс | Языки | Pattern |
|-------|-------|---------|
| Universal | all | `\b(TODO|FIXME|XXX|HACK)\b` |
| Russian-laziness | all | `(дореал\|доделат\|допиш\|потом сдела\|реализу[ею] позже\|implement later\|fix later\|placeholder)` |
| PHP not-impl | php | `throw\s+new\s+\\?\w*Exception\([^)]*(not\s+implemented\|заглушк\|stub\|todo)` |
| PHP die-stub | php | `\bdie\([^)]*(stub\|заглушк\|todo\|not\s+implemented)` |
| Go panic-stub | go | `panic\(\s*"[^"]*(not\s+implemented\|TODO\|todo\|stub\|заглушк)` |
| Go TODO-marker | go | `//\s*TODO[\(:]` |
| JS/TS not-impl | js,jsx,ts,tsx | `throw\s+new\s+Error\([^)]*(not\s+implemented\|TODO\|stub\|заглушк)` |

**Сознательно НЕ детектируется** (false positives):
- Пустые тела функций (легитимны в interface/abstract)
- `console.log` (легитимен в dev tooling)
- Однострочные комментарии без маркеров (могут быть планом)

**Срабатывания:**
- `PreToolUse(Write|Edit|MultiEdit)` → exit 2 → блок записи
- `Stop` → найдено в сессии → JSON `decision:block`

**Оверрайды:**
- Per-line: добавить к строке `// allow-stub: <reason>` — паттерн игнорируется. Маркер также блокирующий, чтобы не остался случайно — отдельный whitelist в `~/.claude/stub-allowlist.txt` по `file:line:reason`.

### 4.2 FDR pipeline (S2, S3, S4)

#### 4.2.1 Артефакт-валидатор (`fdr-validate.sh`)

**Вход:** путь к `fdr-<sid>.md` + список реально изменённых файлов из `edits-<sid>.log`.

**Проверки (exit 2 если хоть одна fail):**

| # | Проверка | Failure message |
|---|----------|-----------------|
| C1 | Файл существует | `FDR artifact missing: run /fdr` |
| C2 | Каждый файл из edits-log в `## Scope` | `Scope incomplete: missing <file>` |
| C3 | Каждый Finding имеет 7 полей: `file:` (минимум `path`; рекомендуется `path:symbol` напр. `app/Wallet.php:transfer`; `path:line` ОБЯЗАТЕЛЬНО только для severity = CRITICAL или HIGH), `layer:`, `scenario:`, `expected:`, `actual:`, `severity:`, `status:` | `Finding F<n> incomplete: missing <field>` или `Finding F<n>: CRITICAL/HIGH без :line` |
| C4 | `severity` ∈ {CRITICAL, HIGH, MEDIUM, LOW} | `Finding F<n>: invalid severity` |
| C5 | `status` ∈ {open, resolved, reopened, partial} | `Finding F<n>: invalid status` |
| C6 | Verdict format корректный: строка 1 `^status:\s*(complete\|incomplete\|degraded)\s*$`, строка 2 `^counts:\s*\d+\s+open\s+/\s+\d+\s+resolved\s*$`. Если есть finding со `status: open` → строка 1 должна быть `status: incomplete` или `status: degraded`, не `complete`. | `Verdict format invalid` или `Verdict mismatch: open findings exist but status says complete` |
| C7 | Если findings_count > 0 И все resolved → `cycles: ≥ 2`. (Если findings никогда не было — `cycles: 1` валиден.) | `Need re-check cycle: cycles must be ≥ 2 after fixes` |
| C8 | Запрещённые секции отсутствуют (по `Persistent Review Rule`). Конкретные detection-regex'ы: `^#{1,3}\s+(coverage\|progress\|history\|highlights\|summary\|резюме\|что проверено\|что было сделано\|recap\|обзор\|заметки\|notes)\b` (заголовки) И `\b(great job\|хорошо сделано\|молодец\|kudos\|отлично\|nicely done\|well done\|good work)\b` (praise inline). Оба прогоняются через `grep -iE` по телу артефакта | `Forbidden section/phrase: <match>` |
| C9 | Если Phase 4 (static-prepass) активен И есть `*.php`/`*.go`/`*.ts`/`*.js` в scope → секция `## Layer 0 (static prepass)` присутствует. Если Phase 4 не внедрён (нет `~/.claude/hooks/static-prepass.sh`) — C9 пропускается | `Static prepass missing (Phase 4 active but no Layer 0 in artifact)` |
| C10 | Если `status: resolved` → обязательны `fix-commit: <sha\|pending>` и `re-check: <ISO timestamp> — <verifier>` | `Finding F<n> resolved without fix-commit/re-check evidence` |
| C11 | Если существует файл `~/.claude/state/bypass-<sid>` с непустой причиной внутри → блок не срабатывает, bypass логируется в `~/.claude/state/bypass-log.jsonl` (см. Q3), файл `bypass-<sid>` удаляется немедленно после первого Stop (одноразовый) | — |

#### 4.2.2 Триаж (Haiku 4.5)

**Вход:** список файлов + diff'ы (head -c 3000 на файл).

**Промпт (EN):**
```
Triage code change for FDR scope. Output JSON only.

Files: <list>
Diffs (truncated):
<diffs>

Output:
{
  "risk": <1-5>,
  "layers": [<subset of 1-9>],
  "bundles": [<subset of A,B,C,D>],
  "rationale": "<one line>"
}

Layer map:
1=context, 2=architecture, 3=logic, 4=contracts, 5=data,
6=security, 7=reliability, 8=performance, 9=tests/observability

Bundle map:
A=1+2+3, B=4+5, C=6+7, D=8+9

Rules:
- CSS/HTML-only: bundles=[A]
- README/docs-only: skip FDR (return risk=0)
- Migrations: B always required, plus C if data sensitivity
- Auth/payment/wallet path: C mandatory
- Test files: D
- Bound: ≤ 4 bundles, ≤ 6 layers
```

**Выход:** JSON, парсится `jq`, передаётся в runner.

**JSON extraction (применять урок Wave 2.5 `judge.sh`):** real Haiku output может содержать preamble или fenced wrap (` ```json ... ``` `). Multi-fallback chain ОБЯЗАТЕЛЕН:
1. `sed -n '/^{/,/^}/p'` — JSON на отдельных строках
2. Если empty → `grep -oE '\{[^}]*"risk"[^}]*\}' | head -1` — inline JSON
3. Если empty → передать raw response в `jq` (jq strict, но иногда работает)
4. Если и это fail → fallback strategy (см. ниже)

**Error handling (если Haiku вернул не-JSON / невалидный schema / claude CLI недоступен):**
- Fallback strategy — все 4 bundles + все 9 layers (conservative).
- Запись в `~/.claude/state/triage-errors-<sid>.log`: timestamp + raw response для дальнейшего анализа prompt'a.
- runner продолжает с fallback-scope, не блокирует пользователя.
- Если 3+ triage-fail подряд за неделю — алерт в health-check.sh (потенциальный prompt-drift).

#### 4.2.3 Bundle-агенты (Sonnet 4.6)

**Промпт каркас (EN, stable prefix → cached):**
```
[STABLE — cached prefix]
You are an FDR reviewer for bundle <X>. Layers: <list>.

Output contract:
- Findings only.
- Format per finding:
  F<n>: file:line | layer | severity | one-line title
  scenario: <repro>
  expected: <correct behavior>
  actual: <observed behavior>
- If clean: respond exactly "0 problems".
- FORBIDDEN: praise, recap, "checked X clean", coverage tables, progress narration, process commentary.
- Severities: CRITICAL, HIGH, MEDIUM, LOW.
- Russian summary at end: 1-2 lines, only if findings exist.

Layer 0 (static analysis) is already covered by phpstan/staticcheck/eslint/tsc — see "## Layer 0" section of the artifact. Do NOT duplicate syntactic checks. Focus on semantic and design issues that static tools cannot detect.

Project rules: <CLAUDE.md slim>
Domain context: <RU, only if relevant>

[VOLATILE]
Scope:
<files>

Diffs:
<diffs, head -c 6000 per file>

Bundle <X> instruction:
<bundle-specific>
```

**Bundle-specific instructions:**
- A (1-3): «Cross-file consistency, architectural boundary breaches, logic correctness, edge cases.»
- B (4-5): «API contracts, DTO/schema validation, data migrations, indexes, transactions, idempotency keys.»
- C (6-7): «AuthN/AuthZ, tenant isolation, secrets in code, input hardening, race conditions, retry safety, partial failure recovery.»
- D (8-9): «N+1 queries, hot loops, allocation hotspots, missing indexes for query patterns, test coverage of new branches, observability gaps (logs/metrics/traces).»

**Output parsing (применять урок Wave 2.5 `judge.sh`):** bundle agents возвращают findings в формате `F<n>: file | severity | title` плюс блоки. Real Sonnet output может содержать markdown-обёртку, preamble или forbidden sections. Parser в /fdr skill body должен:
1. Strip любые fenced-blocks: `awk '/^\`\`\`/ { f=!f; next } !f { print }'` (сохраняем содержимое, убираем markup-fences)
2. Grep `^F[0-9]+:` для извлечения строк findings
3. Если 0 строк matches → trust «0 problems» только если bundle text равен буквально `0 problems` (после trim) — иначе considered как parse failure
4. На parse failure — логируется `bundle-<X>: parse-failed`, в артефакте секция `## Layer X — parse failed: see runner-error log`

#### 4.2.4 Independent verifier (`fdr-verify.sh`, headless `claude -p`)

**Активация:** только если sensitive-path detected ИЛИ переменная `CLAUDE_FDR_VERIFY=1`.

**Тайм-ауты:**
- В `~/.claude/settings.json` для Stop hook задаётся `"timeout": 120000` (мс).
- Сам вызов `claude -p` оборачивается в `timeout 90 claude -p ...`.
- При превышении: в артефакт пишется `verifier: timed-out`, Stop пропускается с soft warning (не block) — лучше пропустить sensitive-проверку, чем заблокировать сессию навсегда.
- Если `claude` CLI отсутствует в PATH — запись `verifier: unavailable`, Stop пропускается.
- Если `claude` есть, но возвращает auth/billing error (exit ≠ 0 без timeout) — запись `verifier: auth-failure`, тот же путь что unavailable.

**Команда:**
```bash
timeout 90 claude -p "$(cat <<'EOF'
You are an independent FDR verifier. The main reviewer claims the artifact below covers all issues. Find up to 5 issues missed.

Output: same compact format. If nothing missed: "0 missed".
FORBIDDEN: re-stating known findings, praise, recap.

Diffs:
<diffs>

Existing findings:
<fdr-<sid>.md>
EOF
)" --output-format json --max-tokens 2000
```

**JSON extraction (тот же multi-fallback что в §4.2.2 triage):** sed → inline grep с key-anchor (`"missed"` или `"file"`) → raw → fallback `verifier: parse-failed`.

**Сравнение:** парсится результат, нормализуем locator (после C3-релаксации finding может быть `file`, `file:symbol` или `file:line`). Verifier-finding считается «новым» если ни один основной finding не имеет того же `file` базового пути (line/symbol игнорируются для match — slight false-negative ок, vs много false-positive). Если найдены новые — `Stop` блок.

**Verdict-формат для verifier:** `0 missed` (clean) ИЛИ список findings в том же формате что bundle agents (`F<n> | file:line/symbol | severity | title`). Не «0 problems» — это термин bundle-agent verdict, у verifier свой словарь.

#### 4.2.5 Re-check после фикса

**Триггер (4 пути, в порядке убывания автоматизации):**
1. **Auto-block при post-fix Stop** — stop-guard.sh при наличии артефакта с open findings AND edits-log mtime > artifact mtime (новые правки после артефакта) → автоматически блокирует Stop с reason «Open findings + new edits detected — invoke /fdr to recheck». Модель НЕ может стопнуться без recheck. Это самый сильный механизм.
2. **Auto-suggest** — если open findings есть, но новых правок нет, stop-guard просто добавляет reminder в Stop reason без блока.
3. **Manual** — пользователь набирает `/fdr recheck` (или просто `/fdr` — runner per §5.2 step 0 определяет ветку).
4. **No git-hook integration** — намеренно, чтобы избежать race condition'ов и поддержать работу без git-репо.

**Что считается «фикс-коммитом»:** не git commit обязательно — достаточно что edits-log mtime > artifact mtime (новые правки после артефакта). Recheck читает diff между mtime артефакта и текущим состоянием файлов.

**Промпт (EN, ~150 tokens):**
```
Re-check fix for findings.

Open findings:
<F1, F2 ... summary>

Fix diff:
<git diff HEAD~1>

For each finding: respond
F<n>: resolved | reopened | partial
evidence: <file:line> or <reason>
```

Один вызов вместо полного нового ФДР. Стоимость ~5% от полного ФДР.

#### 4.2.6 Skip-list (`is-trivial-diff.sh`)

**Базовый ref для git diff:** `HEAD` (working tree против последнего коммита) — для всех скриптов skip-list, runner, recheck. Для projects вне git репозитория `git diff` падает → `is-trivial-diff.sh` возвращает «not trivial» (FDR обязателен) с warning в log. Для интерактивных сессий с активной разработкой это правильный baseline; merge-base логика не нужна (Claude Code не делает PR-flow).

Skip ФДР если ВСЕ изменённые файлы попадают под:

| Класс | Pattern |
|-------|---------|
| Docs | `*.md`, `*.rst`, `*.txt`, `LICENSE`, `CHANGELOG*` |
| Whitespace-only | `git diff -w` пустой |
| Comments-only | для `.php/.go/.js/.ts`: diff содержит только `^[+-]\s*(//|#|/\*|\*)` строки |
| Lockfiles | `*.lock`, `package-lock.json`, `composer.lock`, `go.sum` без изменений в `go.mod` |
| Translation/i18n | `lang/*.json`, `i18n/*.yml` |

Если хоть один файл вне skip-list — ФДР обязателен.

**Precedence: sensitive-paths overrides skip-list.** Если файл совпадает И со skip-list (например, `*.md`), И с sensitive-paths (например, `auth/*`) — ФДР запускается полностью, включая independent verifier. Логика: README в `auth/` может содержать секреты доступа, изменения в `migrations/*.md` (документация миграций) могут отражать критичные изменения схемы.

### 4.3 Token economy (S5, S6, S11)

#### 4.3.1 Static-prepass (`static-prepass.sh`)

Запуск в `PostToolUse(Write|Edit|MultiEdit)` для каждого файла. Механика — строго неблокирующая, без race condition'ов на артефакте:

1. Хук-обёртка делает `nohup <analyzer> ... > ~/.claude/state/prepass-<sid>-<safe-path>-<analyzer>.log 2>&1 &` и сразу exit 0. Tool result не ждёт. **Naming:** `<safe-path>` = sanitized полный путь (`echo "$file" | tr '/' '_' | tr -cd '[:alnum:]._-'`) — не basename, иначе collision между `app/auth/utils.php` и `app/payment/utils.php` (оба → `utils.php` → второй перезаписывает).
2. Каждый аналайзер пишет в свой отдельный лог-файл — никаких параллельных записей в общий артефакт.
3. Сборка в `## Layer 0` секцию `fdr-<sid>.md` происходит ОДИН раз — в начале запуска `/fdr` skill (Phase 3).

**Lock contract (детальный):**
- **Creator:** `static-prepass.sh` PostToolUse-обёртка делает `touch <lock>` ДО запуска nohup-аналайзера, передаёт path lock'а в env переменной `STRICT_PREPASS_LOCK`.
- **Cleaner (happy path):** обёртка-wrapper аналайзера (`exec analyzer "$@"; rm -f "$STRICT_PREPASS_LOCK"`) удаляет lock после завершения analyzer'a. Использовать `trap 'rm -f $STRICT_PREPASS_LOCK' EXIT` для надёжности при kill.
- **Cleaner (stale):** `state-cleanup.sh` (cron daily) удаляет lock'и старше 60 минут как stale (60 = analyzer timeout 20с × 3 buffer). Также `health-check.sh` при SessionStart чистит stale lock'и > 60 мин той же сессии.
- **Wait-strategy в /fdr runner:** проверяет `~/.claude/state/prepass-<sid>-*.log.lock` файлы. Если есть — wait до 25 секунд (timeout analyzer 20с + 5с buffer). Если по истечению lock'и остались → пометить `Layer 0: prepass timed out for: <files>`, продолжить с partial Layer 0.
- **После сборки:** runner удаляет `prepass-<sid>-*.log` и `*.lock` файлы (атомарно, через `rm -f`).
- **Crash recovery:** если analyzer упал не оставив lock — analyzer log пуст или partial → runner парсит что есть, помечает `Layer X: incomplete`. Если analyzer оставил lock но без log file → trap должен был сработать, fallback — stale-cleanup через час.
4. Если на момент Stop без `/fdr` ни один prepass ещё не отработал — агрегация не нужна (skip-list или артефакт не требуется).

Это устраняет конкуренцию за артефакт и не блокирует tool result.

| Язык | Команда | Условие наличия |
|------|---------|-----------------|
| PHP | `vendor/bin/phpstan analyse --no-progress --error-format=raw <file>` | если `vendor/bin/phpstan` существует |
| Go | `staticcheck <pkg>` | если `staticcheck` в PATH |
| Go | `go vet <pkg>` | всегда если go-проект |
| TS | `tsc --noEmit` | если `tsconfig.json` |
| JS/TS | `eslint --no-color --format=compact <file>` | если `.eslintrc*` |

Тайм-аут на инструмент: 20 сек. Падение инструмента не блокирует — просто запись `tool failed`.

**⚠ Security note (F9):** static-analyzers (особенно `phpstan` через `phpstan.neon` с `bootstrap` файлами) могут выполнять **arbitrary code из проекта** при анализе. Это эквивалент `composer install + run` уровня доверия. Опт-аут per-project — создать файл `<project>/.claude/no-static-prepass`, hook пропустит. Рекомендуется отключать на untrusted-репозиториях (чужой код, security research).

#### 4.3.2 Diff-only scope для агентов

Контекст ревьюеру:
- `git diff <merge-base>..HEAD -- <file>` (head -c 6000)
- ±30 строк контекста до/после хунка
- Список затронутых символов (через `git diff --function-context` + extract)
- Полный файл подсасывается **только если ревьюер запросил** через Read.

#### 4.3.3 Cache-friendly briefs

Структура промптов агентам:
1. **STABLE PREFIX** (всегда одинаков, кешируется):
   - Output contract
   - 9-layer rules slim
   - Project base rules
2. **VOLATILE SUFFIX**:
   - Конкретный diff
   - Bundle-specific инструкция

Если в сессии ≥ 2 ФДР подряд (develop→FDR→fix→FDR), второй платит только за volatile.

**Caveat (F23):** Anthropic prompt cache TTL = 5 мин. Если между FDR-циклами проходит > 5 минут (типично для отладки фикса) — кеш промахивается, экономия теряется. Real-world cycle обычно укладывается, но это не гарантировано. На длинных циклах фикса (> 5 мин) мера #7 эффект не даёт.

#### 4.3.4 Model routing

| Задача | Модель |
|--------|--------|
| Триаж ФДР | Haiku 4.5 |
| Re-check после фикса | Haiku 4.5 |
| Bundle-агенты ФДР | Sonnet 4.6 |
| Independent verifier | Sonnet 4.6 |
| Главный поток (разработка) | Opus 4.7 (по умолчанию) |
| Главный поток на простых правках по образцу | Sonnet 4.6 (manual `/model`) |
| Поиск/счёт — задачи без рассуждений | Haiku 4.5 (subagent override) |

#### 4.3.5 Development habits (нормативные правила, не хуки)

Прописываются в новом `~/.claude/CLAUDE.md` как guidelines:

| Правило | Эффект |
|---------|--------|
| Grep before Read; Read with offset/limit | -5..10× на чтении больших файлов |
| Bash output: `\| tail -50` или `\| grep PATTERN` | -90% на build/test outputs |
| Edit > Write на правках | -50× на размере выхода |
| Subagent только если scope ≥ 3 файла или > 500 строк | избегает пере-загрузки контекста |
| `respond in N words` для субагентов | без этого они возвращают простыни |
| `/clear` между несвязанными задачами | избегает компакта |
| Plan first на нетривиальных задачах | избегает rework |
| Не сидеть > 270 сек между турнами в одной задаче | сохраняет prompt cache |
| Параллельные tool calls для независимых операций | один префикс на батч |
| LLM формулирует запрос, shell считает (`wc -l`, `grep -c`, MCP-агрегация) | избегает «счёта в уме» через LLM на > 5 объектов |
| ScheduleWakeup на 270s (в кеше) или ≥ 1200s (амортизация miss), не 300s | минимизирует cache misses при ожидании билдов/задач |
| Brief output contract в каждом промпте субагенту: «respond in N words», «findings only», «no preamble» | без этого субагент возвращает простыни |
| Не делегировать субагенту то, что делается одним Grep + Read в главном потоке | субагент = свой контекст = повторное чтение файлов |

#### 4.3.6 Token budget alerter

В `Stop` hook после успешного ФДР подсчитывается:
- Количество tool calls (через transcript scan)
- Размер `fdr-<sid>.md`
- Размер `edits-<sid>.log`

Если превышены пороги (configurable):
- 100 tool calls → soft warning «session is getting expensive»
- > 50 файлов в edits-log → требование декомпозиции

Не блокирует.

#### 4.3.7 Self-imposed output contract

Правила, добавляемые в новый `~/.claude/CLAUDE.md` (Phase 7) для дисциплины модели на выходе. Каждое режет 100–500 токенов на турн; на сессии в 50 турнов — 5–25k.

| Правило | Расшифровка |
|---------|-------------|
| Не пересказывать diff в конце турна | пользователь и так видит изменения, end-summary избыточен |
| «Существует ли X?» / «Готов ли Y?» → `да`/`нет` + `file:line`, без преамбулы | вопросы существования и статуса не требуют рассуждений |
| Bash output не дампить — выжимка: что упало, где, как починить | сырой вывод не нужен в контексте |
| Комментарии в коде — только если *почему* неочевидно | system prompt уже это требует, в CLAUDE.md явное укрепление |
| Не предлагать «давай ещё сделаю Y» в конце реализации X | вопрос пользователю — отдельный осознанный жест |
| Не цитировать только что озвученные правила («следуя CLAUDE.md…», «как ты говорил…») | избыточная самоссылка |
| Заголовки/секции — только при ответе ≥ 5 параграфов | на коротких ответах лишняя структура |
| Не вставлять emoji, если пользователь не попросил | system prompt уже требует — укрепляем |

### 4.4 Auto-context hygiene (S7)

#### 4.4.1 Подрезка `claude-mem-context`

Эта таблица сейчас в проектном `CLAUDE.md` (по `<claude-mem-context>` тегам). Содержит даты, ID, тип, заголовок и read-count.

**Стратегия:**
- Хранить только последние **7 дней** активности.
- Группировать по дате; за каждый день максимум 5 записей с самым высоким `read`.
- Удалять записи старше 7 дней автоматом.

**Реализация:** скрипт `prune-mem.sh` (cron weekly) парсит markdown между маркерами и перезаписывает.

**Точная спецификация парсера:**
- Маркеры начала/конца блока: строки `<claude-mem-context>` и `</claude-mem-context>` (HTML-style тег, не markdown).
- Файлы для обработки: `~/.claude/CLAUDE.md` и `/Users/andrey/CLAUDE.md` (если существует).
- Бекап перед каждой записью: копия в `~/.claude/state/mem-backup-<ISO>.md` (последние 7 бекапов хранятся, старше — удаляются).
- Внутри блока структура: `### MMM D, YYYY` заголовки + markdown-таблицы с полями `| ID | Time | T | Title | Read |`.
- Формат даты: `Feb 7, 2026` (English locale, `%b %-d, %Y` для `date`).
- Парсер: **python3** (на macOS системно), не bash regex — bash слишком хрупок на multiline markdown:
  ```python
  # ~/.claude/hooks/prune-mem.py
  # Reads CLAUDE.md, finds <claude-mem-context>...</claude-mem-context> block,
  # parses ### date headers, drops entries older than N days (default 7),
  # caps daily entries to 5 most-read, writes back.
  # Usage: python3 prune-mem.py <path> [--days N] [--max-per-day M]
  ```
- Cron: `0 4 * * 1 python3 $HOME/.claude/hooks/prune-mem.py $HOME/.claude/CLAUDE.md --days 7 --max-per-day 5`.
- Безопасность: если регекспы парсера не нашли start/end маркеры — выход без изменений + лог в `~/.claude/state/prune-errors.log`. Никогда не переписывать файл, который не распарсился.

**Эффект:** -3..7k токенов на каждый турн.

#### 4.4.2 `MEMORY.md` grooming

- Удалять ссылки на несуществующие файлы.
- Удалять записи помеченные как stale (поле `last_verified` старше 30 дней без обновления).
- Объединять дубликаты.

**Реализация:** ручная ревизия + опциональный helper `groom-memory.sh`.

#### 4.4.3 Memory writing style

Конвенция для новых записей в `~/.claude/projects/-Users-andrey/memory/`:

| Поле | Язык | Обоснование |
|------|------|-------------|
| `name` (frontmatter) | RU | человек просматривает в `MEMORY.md` |
| `description` (frontmatter) | RU | используется тобой для решения «релевантна ли память сейчас» — должна быть понятна с одного взгляда |
| Body | EN compact | модель видит чаще, чем человек; экономия 30–40% объёма |
| Domain terms внутри body | RU | непереводимы (`казённый`, `tenant`, `поставщик P`, `ЗП-сверка`) |
| `MEMORY.md` index entry | RU title + EN hook | пример: `- [Wallet system](wallet-system.md) — TRC20 wallet management at tools.digoo.com/wallet` |
| `**Why:**` / `**How to apply:**` блоки | EN | служебные структурные поля, видит только модель |

Старые записи мигрируются постепенно — при касании. Не делать массовую конверсию, чтобы избежать риска перевода доменных терминов.

#### 4.4.4 State directory cleanup

`~/.claude/state/` накапливает per-session артефакты. Без чистки — рост на сотни файлов в неделю при активной работе.

**Политика хранения:**

| Категория | Retention | Действие при истечении |
|-----------|-----------|-----------------------|
| Per-session: `edits-*.log`, `fdr-*.md`, `fdr-verify-*.md`, `trivial-flag-*`, `bypass-*`, `prepass-*.log`, `hook-errors-*.log` | 30 дней с момента последней модификации | удалить |
| Persistent audit: `bypass-log.jsonl`, `blocks.jsonl` | бессрочно | архивировать в `state/archive/<YYYY>/` если > 50 МБ |
| Бекапы: `mem-backup-*.md` | последние 7 ротируются автоматически (см. §4.4.1) | удалить старшие |
| `prune-errors.log` | 90 дней | удалить |

**Реализация:** `~/.claude/hooks/state-cleanup.sh`, cron daily в 4 утра:
```bash
find ~/.claude/state -maxdepth 1 -type f \( \
  -name 'edits-*.log' -o -name 'fdr-*.md' -o -name 'fdr-verify-*.md' \
  -o -name 'trivial-flag-*' -o -name 'bypass-*' \
  -o -name 'prepass-*.log' -o -name 'hook-errors-*.log' \
  \) -mtime +30 -delete
```
Audit-логи специально не чистятся.

### 4.5 Sensitive-path detection (S10)

**Файл:** `~/.claude/sensitive-paths.txt` (по одному ERE-regex на строку, синтаксис `grep -E`).

**Синтаксис:** ERE (Extended Regular Expressions) через `grep -E -f sensitive-paths.txt`. Anchors (`^`, `$`) обязательны если нужен полный match. Для путей с расширениями — экранировать точку (`\.`). Не используется PCRE (`\b`, lookaheads), потому что macOS `grep` не всегда его поддерживает.

**Скрипт `is-sensitive.sh`:**
```bash
#!/usr/bin/env bash
# is-sensitive.sh <absolute-path>
# Exit 0 if matches any pattern, 1 otherwise.
[[ -z "${1:-}" ]] && exit 1
printf '%s\n' "$1" | grep -E -q -f "$HOME/.claude/sensitive-paths.txt"
```

**Содержание `sensitive-paths.txt`:**
```
.*/auth/.*
.*/payment/.*
.*/wallet/.*
.*/security/.*
.*/migrations/.*
.*\.sql$
.*/agent_c/.*
^/opt/agent_c/.*
.*/inventory_.*
.*/inventory-admin/.*
.*/ZP/.*
.*/ЗП/.*
.*\.env(\.|$)
.*/secrets?/.*
.*/credentials?/.*
```

**Используется в:**
- `Stop` hook → решает, запускать `fdr-verify.sh` (§4.2.4)
- Будущее (v1.1): `PreToolUse(Write|Edit|MultiEdit)` → дополнительный strict-mode reminder при правке sensitive

### 4.6 UserPromptSubmit reminder (S9)

**Длина:** ≤ 120 токенов (фактический замер — см. §6 Phase 9 методологию). Если выходит за — сокращать.
**Язык:** EN с RU output policy reminder.

Компактный текст:
```
[STRICT MODE]
1. No stubs (TODO/FIXME/not implemented). Code complete to working state.
2. After any code edit: mandatory FDR (9 layers, /fdr). Cycle until 0 findings.
3. Findings need: file:line, scenario, expected, actual, severity.
4. Do exactly what's asked. "Изучи" = study, not edit. When unsure, ask.
5. Reply in Russian. Code comments Russian. FDR/briefs English.
6. Sensitive paths (auth/wallet/payment/migrations/agent_c) → run independent verifier.
```

### 4.7 Оценка экономии по мерам

| # | Мера | Эффект | Сложность | Где живёт |
|---|------|--------|-----------|-----------|
| 1 | Подрезать `claude-mem-context` до 7 дней | −3..7k токенов на каждый турн | 5 мин разовая | `prune-mem.sh` + cron |
| 2 | Переписать `~/.claude/CLAUDE.md` на EN с RU output policy | −2..3k токенов на каждый турн | 1 час разовая | Phase 7 |
| 3 | Persistent Review Rule на EN | −50 токенов / турн | 5 мин | переписан в `CLAUDE.md` |
| 4 | Diff-only scope для агентов | −5..20× на чтении больших файлов | в `/fdr` skill body | Phase 3 |
| 5 | Layer collapse 9 → 4 bundle | −55% на API-вызовы ФДР | в `/fdr` skill body | Phase 3 |
| 6 | Триаж на Haiku → выбор слоёв | −40..60% на запусках агентов | в `/fdr` skill body | Phase 3 |
| 7 | Cache-friendly briefs (stable prefix + volatile suffix) | −50..80% на повторных циклах ФДР | в `/fdr` skill body | Phase 3 |
| 8 | Re-check через diff фикса, не полное ФДР | −75% на цикле фиксов | в `/fdr` skill body | Phase 6 |
| 9 | Skip-list для тривиальных правок | −100% ФДР на тривиях | `is-trivial-diff.sh` | Phase 2 |
| 10 | Selective independent verifier | −100% от уровня 2 на не-sensitive путях | `is-sensitive.sh` + `fdr-verify.sh` | Phase 5 |
| 11 | Compact FDR-артефакт (EN, однострочные findings) | −50..70% размера артефакта | в `/fdr` skill body | Phase 3 |
| 12 | Static analyzers как Layer 0 | 30..50% находок без LLM | `static-prepass.sh` | Phase 4 |
| 13 | Brief output contract субагентам в каждом промпте | −1..2k на каждый субагент-вызов | в каждом промпте | Phase 1+ |
| 14 | Self-imposed output contract в CLAUDE.md | −100..500 токенов на каждый турн на выходе | строки в `CLAUDE.md` | Phase 7 |
| 15 | RU/EN tokenization ratio (~2×) для всех внутренних текстов | покрывается мерами 2, 3, 11, 13 | — | — |
| 16 | Grep before Read; Read с offset/limit | −5..10× на чтении больших файлов | привычка + правило в CLAUDE.md | Phase 7 |
| 17 | Bash output \| tail/grep | −90% на build/test outputs | привычка + правило | Phase 7 |
| 18 | Edit > Write на правках | −50× на размере выхода | привычка | system prompt уже требует |
| 19 | `/clear` между несвязанными задачами | избегает компакта (−1 LLM-вызов на компакт) | привычка | Phase 7 |
| 20 | Plan first на нетривиальных задачах | −1..3× на rework | привычка | Phase 7 |

**Топ-3 ROI (внедрить первыми, до полной системы):**
1. **Подрезка `claude-mem-context`** — 5 минут работы, эффект каждый турн навсегда. Не требует никаких хуков.
2. **Перевод `~/.claude/CLAUDE.md` на EN + slim** — 1 час работы, эффект каждый турн навсегда.
3. **Layer collapse 9→4 + триаж на Haiku** — главный выигрыш на ФДР, окупается за день.

Эти три вместе дают ~50% от целевой экономии (G4) ещё до внедрения остальной механики.

---

## 5. Конфигурация

### 5.1 `~/.claude/settings.json` — блок `hooks`

См. отдельный файл implementation-config (генерируется в Phase 1+).

Скелет (с явными timeout'ами под §4.2.4 и health-check):
```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "$HOME/.claude/hooks/health-check.sh", "timeout": 5000}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "$HOME/.claude/hooks/prompt-inject.sh", "timeout": 3000}]}
    ],
    "PreToolUse": [
      {"matcher": "Write|Edit|MultiEdit",
       "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/pre-write-scan.sh", "timeout": 5000}]}
    ],
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit",
       "hooks": [
         {"type": "command", "command": "$HOME/.claude/hooks/record-edit.sh", "timeout": 3000},
         {"type": "command", "command": "$HOME/.claude/hooks/static-prepass.sh", "timeout": 3000}
       ]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "$HOME/.claude/hooks/stop-guard.sh", "timeout": 120000}]}
    ],
    "SubagentStop": [
      {"hooks": [{"type": "command", "command": "$HOME/.claude/hooks/stop-guard.sh", "timeout": 30000}]}
    ]
  }
}
```

**Замечания по timeout-значениям:**
- `Stop: 120000ms` — учитывает потенциальный 90s `claude -p` верификатор (§4.2.4) + парсинг артефакта.
- `SubagentStop: 30000ms` — субагент не запускает heavy верификатор (§Q6), хватает обычной валидации stub-detection.
- `PostToolUse: 3000ms` — все скрипты должны быть ≤ 3 сек: `record-edit.sh` это echo в файл, `static-prepass.sh` спавнит nohup и сразу exit (см. §4.3.1).
- `PreToolUse: 5000ms` — `pre-write-scan.sh` должен быть быстрым (regex по контенту diff'а через `jq`).
- `SessionStart: 5000ms` — health-check проверяет `jq`, `git`, `timeout`, размер CLAUDE.md, наличие `~/.claude/state/`.
- Если хук превышает timeout — Claude Code прервёт его. Поведение: для PreToolUse это станет non-blocking warning (инструмент пройдёт), для Stop — переход на следующий хук в цепочке.

### 5.2 Skill `~/.claude/skills/fdr/SKILL.md`

```yaml
---
name: fdr
description: Run Full Deep Review on session edits — triage + bundle agents + diff recheck. Triggers on "/fdr", "ФДР", "FDR", "проведи ревью", "ревью", "full deep review".
allowed_tools: [Bash, Read, Grep, Agent]
---

# FDR Runner

Orchestrates 9-layer Full Deep Review with token-economy optimizations. **Skill body is a prompt for Claude itself**, not a shell script. Claude executes the steps below using its own tools (Bash, Read, Grep, Agent).

Steps:
0. **Branch initial vs recheck:** условие recheck — артефакт существует AND есть open findings AND **edits-log mtime > artifact mtime** (новые правки появились ПОСЛЕ создания артефакта = есть что rechek'ать). Если только cycles≥1 + open findings без новых правок — это «висящий артефакт без работы», тогда: predict «work in progress, нечего rechek'ать», вернуть статус-сообщение, не запускать subagents. Иначе (нет артефакта вовсе ИЛИ артефакт без open findings) — initial flow (steps 1-7 ниже).
1. **Compute scope:** `bash` to read `~/.claude/state/edits-<sid>.log`, `sort -u`. Filter via `[[ -f $path ]]`. Add orphan subagent edits ONLY IF `~/.claude/state/orphan-edits.log` exists AND `~/.claude/state/session-start-<sid>` exists (см. §Q6 fallback). Run `git diff --name-only` against `HEAD` for related files (depth=1 imports/usages via Grep).
2. **Aggregate static prepass:** `cat ~/.claude/state/prepass-<sid>-*.log` → write to `## Layer 0` of `fdr-<sid>.md.tmp`. Delete intermediate `prepass-*.log`.
3. **Triage on Haiku:** invoke `Agent` tool with `subagent_type: "general-purpose"`, `model: "haiku"`, prompt = §4.2.2 triage prompt. Parse JSON output for `bundles`/`layers`.
4. **Bundle agents in parallel:** invoke `Agent` tool **multiple times in a single message** (per system prompt: independent agents → one message with multiple tool uses), one per active bundle (A/B/C/D), `subagent_type: "general-purpose"`, `model: "sonnet"`, prompt per §4.2.3 with stable prefix + bundle-specific suffix. NOT `claude -p` — Agent tool keeps native subagent semantics and project context.
5. **Aggregate findings** from all bundle agent results into `fdr-<sid>.md.tmp`.
6. **Atomic finalize:** `mv fdr-<sid>.md.tmp fdr-<sid>.md`. On runner error — leave `.tmp` and write `runner-error-<sid>.log`.
7. **If findings exist** → return list to main thread for fixing. After fix commit, user invokes `/fdr-recheck` (separate skill or argument).

**`/fdr-recheck` — это аргумент того же `/fdr` skill'а**, не отдельный skill. Запуск: `/fdr recheck` (или просто `/fdr` после фиксов — runner детектирует `cycles ≥ 1` в существующем артефакте и автоматически идёт по recheck-ветке). Реализация: skill body проверяет наличие `fdr-<sid>.md` и его `cycles:` поле; если ≥ 1 и есть открытые findings — выполняет recheck flow (§4.2.5) одним Haiku-вызовом через `Agent` tool, обновляет статусы и инкрементирует `cycles:`, атомарный mv. Это исключает skill-conflict (только один skill `fdr` для всего FDR-цикла).
```

---

## 6. План внедрения (фазы)

| # | Фаза | Длительность | Артефакты | Зависимости |
|---|------|-------------|-----------|-------------|
| 0 | Подготовка: каталоги, jq, бекап текущего settings.json и CLAUDE.md | 0.5 дня | `~/.claude/{hooks,skills,specs,state}/` готовы | — |
| 1 | Stub-detection + UserPromptSubmit + SessionStart health-check. **Стартовая точка — v0 прототипы скриптов из исходного обсуждения (chat 2026-04-29 turn 2)**: `stub-scan.sh`, `pre-write-scan.sh`, `record-edit.sh`, `stop-guard.sh`. Их нужно расширить до полной функциональности §4.1 (allow-stub whitelist, sensitive-aware reminders), добавить fail-loud dependency check (§1 Environment) и интеграцию с FDR-валидатором (Phase 2). **Параллельная задача:** отредактировать `~/.claude/skills/enhanced-code-review/SKILL.md` — убрать триггеры `["ревью","ФДР","FDR","review","full deep review"]`, оставить `["/fdr-deep","deep review","глубокое ревью"]` (см. §11 Skill conflict resolution). | 1 день | `stub-scan.sh`, `pre-write-scan.sh`, `record-edit.sh`, `prompt-inject.sh`, `health-check.sh`, hooks block в settings, обновлённый `enhanced-code-review/SKILL.md` | Phase 0 |
| 2 | FDR enforcement core: артефакт + валидатор + Stop guard. **Stop-guard.sh расширение (значимое):** Wave 2 stop-guard только сканит стабы. Wave 3 версия дополнительно: (a) если есть `~/.claude/state/edits-<sid>.log` непустой AND нет `~/.claude/state/fdr-<sid>.md` AND не trivial-diff → block с «invoke /fdr»; (b) если артефакт есть → запустить `fdr-validate.sh` → пробросить findings; (c) если артефакт есть AND open findings AND `mtime(edits-log) > mtime(artifact)` → auto-block recheck (см. §4.2.5 trigger #1); (d) sensitive-paths detected → запустить `fdr-verify.sh` (Phase 5). Все 4 проверки idempotent, безопасно игнорировать если соответствующая Phase не установлена (`[[ -x fdr-validate.sh ]]` guards). | 2 дня | `fdr-validate.sh`, `stop-guard.sh` (расширенный), `is-trivial-diff.sh` | Phase 1 |
| 3 | FDR runner skill (триаж + bundle agents). **NB:** runner это skill body (инструкции для Claude через Agent tool), НЕ shell-скрипт. См. §5.2. **Параллельная задача:** расширить `health-check.sh` (Wave 2) для создания `~/.claude/state/session-start-<sid>` (touch) на старте сессии — необходимо для §Q6 orphan-edits fallback. | 2 дня | `~/.claude/skills/fdr/SKILL.md` + дополненный `health-check.sh` | Phase 2 |
| 4 | Static prepass | 1 день | `static-prepass.sh`, интеграция с PostToolUse | Phase 1 |
| 5 | Sensitive-path verifier (headless) | 1 день | `is-sensitive.sh`, `fdr-verify.sh`, sensitive-paths.txt | Phase 2 |
| 6 | Re-check pipeline | 0.5 дня | `/fdr-recheck` slash inside skill | Phase 3 |
| 7 | Language strategy: переписать `~/.claude/CLAUDE.md` на EN с RU output policy, slim до < 2.5k токенов | 1 день | новый CLAUDE.md, бекап старого | — (parallel) |
| 8 | Auto-context hygiene: `prune-mem.py` для `claude-mem-context`, `state-cleanup.sh` для state-каталога, ручной groom `MEMORY.md` | 0.5 дня | `prune-mem.py`, `state-cleanup.sh`, 2 cron entries (weekly + daily) | — (parallel) |
| 9 | Замеры до/после: токены на типовых задачах. **Методология:** (1) выбрать 3 эталонных task: «правка одного PHP-файла + ФДР», «рефакторинг через 5 файлов с миграцией + ФДР», «небольшое исследование репо без правок». (2) Запустить каждый task в чистой сессии до внедрения, зафиксировать `/cost` cumulative input/output tokens из Claude Code UI. (3) Повторить после Phase 7+8 в чистой сессии. (4) Сравнить и зафиксировать в `~/.claude/specs/measurement-2026-XX.md`. Целевой G4 — снижение на 40%+ на каждом из 3 task'ов | 0.5 дня | замер-отчёт + сохранённые выходные `/cost` | все |
| 10 | Документация: README в `~/.claude/`, troubleshooting | 0.5 дня | doc | все |

**Итого:** ~10 рабочих дней при последовательном внедрении. С параллелизацией phase 7 и 8 — ~8 дней.

---

## 7. Критерии приёмки (по фазам)

### Phase 1 (Stub-detection)
- [ ] Попытка записать файл с `TODO` блокируется.
- [ ] Попытка записать файл с `panic("TODO")` блокируется (Go).
- [ ] Попытка записать с `throw new Error("not implemented")` блокируется (TS).
- [ ] Чистый код проходит без задержки > 200ms.
- [ ] `UserPromptSubmit` инжектит reminder, видно в `transcript_path`.
- [ ] Whitelist (`~/.claude/stub-allowlist.txt`) работает.

### Phase 2 (FDR enforcement core)
- [ ] После code-edit `Stop` блокируется, если `fdr-<sid>.md` отсутствует.
- [ ] Если `fdr-<sid>.md` без всех 7 полей в Finding (file/layer/scenario/expected/actual/severity/status) — блок.
- [ ] Trivial-diff (только README) пропускается на уровне `is-trivial-diff.sh` (до /fdr).
- [ ] Файл из edits-log, не упомянутый в `## Scope` — блок с указанием.
- [ ] Артефакт-гейт работает по принципу «valid artifact или нет», без флагов состояния (флаговая модель Wave 2.5 не применяется к артефакт-гейту).
- [ ] **Auto-block recheck:** если `mtime(edits-log) > mtime(artifact)` AND есть open findings → Stop блокируется с reason «invoke /fdr to recheck» (см. §4.2.5 trigger #1).
- [ ] **Verdict format**: validator принимает 2-line format (`status: X` + `counts: N open / M resolved`), отвергает single-line вариант.
- [ ] Stop-guard idempotent: если соответствующая Phase не установлена (`fdr-validate.sh` отсутствует, `fdr-verify.sh` отсутствует) — соответствующие проверки skip'аются без ошибки.

### Phase 3 (FDR runner)
- [ ] `/fdr` запускается, читает edits-log, делает триаж.
- [ ] Триаж определяет ≤ 4 bundle'а на основе путей и diff.
- [ ] Bundle-агенты запускаются параллельно.
- [ ] Артефакт собирается в правильном формате.
- [ ] На trivial scope `/fdr` НЕ вызывается — отлавливается `is-trivial-diff.sh` (Phase 2). Если /fdr всё-таки запущен на trivial — короткий verdict без bundle-вызовов.

### Phase 6 (Re-check pipeline)
- [ ] `/fdr` после фиксов детектирует существующий артефакт с открытыми findings → переходит в recheck-ветку (§5.2 step 0).
- [ ] Recheck использует только Haiku (1 вызов вместо 4 bundles).
- [ ] Statuses обновляются (`open` → `resolved`/`reopened`/`partial`), `cycles:` инкрементируется.
- [ ] При наличии fix-commit — пишется git SHA, иначе `pending`.
- [ ] Атомарный mv `.tmp` → финальный артефакт.

### Phase 4 (Static prepass)
- [ ] phpstan/staticcheck/eslint вызываются по PostToolUse.
- [ ] Layer 0 пишется в `fdr-<sid>.md`.
- [ ] Падение инструмента не ломает hook.

### Phase 5 (Sensitive verifier)
- [ ] Правка в `*/wallet/*` → запускается `claude -p` верификатор.
- [ ] Findings верификатора, отсутствующие в основном артефакте, блокируют Stop.
- [ ] Правка вне sensitive — верификатор не запускается.

### Phase 7 (Language)
- [ ] Новый CLAUDE.md ≤ 2.5k токенов.
- [ ] В сессии ответы пользователю всё ещё на русском.
- [ ] Промпты субагентам и stderr хуков на английском.
- [ ] FDR-артефакт на английском в compact-формате.

### Phase 8 (Auto-context hygiene)
- [ ] `claude-mem-context` ≤ 7 дней.
- [ ] `MEMORY.md` ≤ 200 строк.
- [ ] Cron weekly работает.

### Глобальные (по всем фазам)
- [ ] G4: на 3 типовых задачах замер показывает -40% токенов или больше.
- [ ] G6: за неделю эксплуатации не возникает ручных «дочисти» / «проведи ФДР».

---

## 8. Риски и компенсации

| # | Риск | Вероятность | Удар | Компенсация |
|---|------|-------------|------|-------------|
| R1 | Ложные срабатывания stub-сканера на легитимных TODO | средняя | низкий | whitelist + per-line `// allow-stub: <reason>` |
| R2 | FDR-валидатор слишком строг → постоянные блоки | средняя | средний | bypass через создание файла `~/.claude/state/bypass-<sid>` с причиной в теле; одноразовый (удаляется после первого Stop), логируется в `bypass-log.jsonl` |
| R3 | Headless verifier дорогой по токенам | средняя | средний | activate только sensitive-paths + явный флаг, по умолчанию off |
| R4 | Триаж на Haiku ошибается → нужный слой пропущен | низкая | средний | минимум 1 bundle всегда (A); periodic audit |
| R5 | Кеш-неточная адресация: stable prefix меняется → миссы | низкая | средний | контролируемые префиксы, тесты на стабильность |
| R6 | Skip-list пропускает реально опасные правки | низкая | высокий | sensitive-paths переопределяет skip-list (если sensitive — skip игнорируется) |
| R7 | На macOS bash 3.2 регекспы поведут себя иначе | средняя | средний | shebang `#!/usr/bin/env bash` + проверка версии при инсталляции, советовать `brew install bash` |
| R8 | Ответы пользователю случайно перешли на английский | средняя | низкий | UserPromptSubmit reminder + явная политика в первой строке CLAUDE.md |
| R9 | Конфликт со существующими hooks пользователя | низкая | средний | мерж в settings.json вручную, не перезатирать |
| R10 | Skill `enhanced-code-review` уже есть — конфликт со `/fdr` | средняя | низкий | new skill называется `fdr` (короткий alias), `enhanced-code-review` остаётся как deeper variant |

---

## 9. Open questions

| # | Вопрос | Решение |
|---|--------|---------|
| Q1 | Должен ли `/fdr` быть автоматически вызываемым из Stop, или требовать ручного запуска? | Stop требует наличия артефакта. Если артефакта нет — Stop предлагает «вызови /fdr». Автозапуск опасен (может уйти в петлю). Полу-автомат. |
| Q2 | Как отличить commit-фикс от случайного edit для re-check? | Re-check работает по флагу `~/.claude/state/fix-cycle-<sid>` (ставится из `/fdr` skill вручную перед фиксом). |
| Q3 | Куда писать обоснование force-bypass и какой scope? | Bypass — это создание файла `~/.claude/state/bypass-<sid>` с причиной внутри (одна строка). Файл одноразовый: после первого Stop, который его учёл, файл удаляется автоматически. Каждое использование append'ится в `~/.claude/state/bypass-log.jsonl` (timestamp, session_id, reason, edited_files). Scope: только эта сессия, только этот Stop. Для повторного bypass нужен новый файл. SessionStart hook не наследует bypass'ы из предыдущих сессий (даже если файл остался — match по session_id не сойдётся). |
| Q4 | Что делать с проектами, где есть свой собственный `AGENTS.md` с противоречащими правилами? | `AGENTS.md` главнее — `Stop` hook читает `AGENTS.md` если есть в `cwd`, экстрагирует строки `# claude-strict-mode: <opt>` и применяет оверрайды. |
| Q5 | Как тестировать всю систему без реального LLM-расхода? | mock-режим: вместо `claude -p` — `cat ~/.claude/mocks/<scenario>.json`. |
| Q6 | Срабатывает ли всё это в субагентах? | Stub-detection работает в субагенте (PreToolUse триггерится одинаково). Edits субагента **должны попадать в parent edits-log**, чтобы попадать в parent FDR scope. Реализация: `record-edit.sh` определяет parent_session_id через переменную окружения `CLAUDE_PARENT_SESSION_ID` (харнесс должен пробрасывать) либо через stdin JSON (`.parent_session_id`); если parent есть — пишет в `edits-<parent_sid>.log`. SubagentStop запускает `stop-guard.sh`, но **валидация артефакта пропускается** (артефакт делает parent после агрегации subagent-правок). Если харнесс не пробрасывает parent_sid — fallback: subagent-edits помечаются `record-edit.sh` как orphan-записи в общем `~/.claude/state/orphan-edits.log` (формат: `<unix-timestamp> <subagent_sid> <abs-path>`). Parent's `stop-guard.sh` при чтении edits-log дополнительно делает: `awk -v start=$session_start_ts '$1 > start' orphan-edits.log | cut -d' ' -f3- | sort -u`. **Session start timestamp source (правильный):** SessionStart hook (`health-check.sh`) на старте создаёт `~/.claude/state/session-start-<sid>` (touch с mtime = реальный старт сессии). stop-guard читает mtime ЭТОГО файла, не edits-log (mtime последнего обновляется на каждый append → бесполезен как session-start indicator). Если файла нет — fallback к stdin JSON `.session_start` (если харнесс передаёт), иначе все orphan-edits игнорируются с warning. |
| Q7 | Нужно ли логировать каждое блокирующее срабатывание? | Да: `~/.claude/state/blocks.jsonl` (append). По нему — еженедельный отчёт. |
| Q8 | Как изменения в settings.json применяются — нужен ли перезапуск Claude Code? | По данным харнесса — settings перечитывается на старте сессии. После изменений: завершить текущий и начать новый. |
| Q9 | Как обрабатывать worktree-режим (Agent с `isolation: "worktree"`)? | Subagent в worktree пишет правки в `~/.claude-worktree-XXX/...`. После завершения worktree удаляется → пути в edits-log невалидны. **Решения:** (1) `record-edit.sh` определяет, что путь под `~/.claude-worktree*/` или вне CWD parent'а — пропускает запись (изоляция означает не наследовать в parent FDR), либо помечает запись как `worktree:`. (2) `stop-guard.sh` фильтрует edits-log через `[[ -f $path ]]` — несуществующие файлы пропускаются. (3) Если worktree merge'ится обратно в основной репо — финальные правки на «настоящих» путях попадут в edits-log при merge-commit и пройдут FDR. |
| Q10 | Что если в проекте свой `phpstan.neon` / `staticcheck.conf` / `.eslintrc` с другими правилами? | `static-prepass.sh` использует **проектные конфиги**, не глобальные. Запуск из `cwd` проекта (`cd "$CLAUDE_PROJECT_DIR" && phpstan analyse ...`). Если конфига нет — аналайзер пропускается с записью в `prepass-*.log`. |
| Q11 | Можно ли запускать `/fdr` без edits в сессии (например, для ad-hoc ревью существующего кода)? | Да: `/fdr <file1> <file2> ...` принимает явный scope. В этом случае edits-log не используется, и Stop hook не требует артефакта. Полезно для ревью PR-веток, чужого кода, исследовательских задач. |
| Q12 | Что происходит, если `/fdr` runner падает на середине? | Артефакт `fdr-<sid>.md` пишется атомарно: сначала во `fdr-<sid>.md.tmp`, потом `mv`. При падении — runner оставляет `.tmp` и `runner-error-<sid>.log` с трассировкой. Stop валидатор не находит финального артефакта → блокирует с сообщением «FDR runner failed, see runner-error-<sid>.log». Bypass через одноразовый `bypass-<sid>` (см. Q3). |

---

## 10. Метрики успеха (через 2 недели после Phase 10)

| Метрика | Цель |
|---------|------|
| Кол-во ручных «дочисти», «проведи ФДР» | 0 / неделя |
| Кол-во заглушек, попавших в коммит | 0 |
| Среднее время ФДР-цикла (develop→FDR→fix→FDR→verdict) | < 10 мин |
| Среднее токенов на ФДР | < 30k |
| Среднее токенов на турн (по сравнению с baseline) | -40% |
| Кол-во ложных блоков от хуков | < 1 / неделя |
| Кол-во force-bypass | < 1 / неделя |
| `~/.claude/CLAUDE.md` размер | ≤ 2.5k токенов |
| `claude-mem-context` глубина | ≤ 7 дней |

---

## 11. Связь с существующими ресурсами

| Существующее | Отношение |
|--------------|-----------|
| `~/.claude/CLAUDE.md` (текущий) | Будет переписан в Phase 7. Бекап → `~/.claude/CLAUDE.md.bak-2026-04-29`. |
| Skill `enhanced-code-review` | Остаётся как «глубокий вариант» через `/fdr-deep`. По умолчанию используется новый `/fdr`. **Phase 1 task:** отредактировать `~/.claude/skills/enhanced-code-review/SKILL.md` — убрать триггеры `["ревью", "проведи ревью", "фдр", "ФДР", "FDR", "code review", "review", "full deep review"]`, оставить только `["/fdr-deep", "deep review", "глубокое ревью", "ФДР глубокий"]`. Новый `/fdr` skill (`~/.claude/skills/fdr/`) забирает основные триггеры: `["/fdr", "ФДР", "FDR", "ревью", "проведи ревью", "full deep review"]`. Это устраняет conflict — у каждой команды одна skill. |
| Skill `enhanced-planning` | Используется на стадии планирования перед реализацией (Plan first из 4.3.5). |
| `Persistent Review Rule` (в текущем CLAUDE.md) | Включён как C8 в `fdr-validate.sh`. |
| AGENTS.md проектов | Главнее глобальных правил (Q4). |
| `claude-mem` плагин | Источник `<claude-mem-context>` — настраивается на retention 7 дней. |
| Memory system (`MEMORY.md` + per-file) | Сохраняется. Бренд-стайл: RU title + EN body для новых записей. |

---

## 12. Применимость 7 чеков консистентности

| Check | Результат |
|-------|-----------|
| Completeness | Все 7 уровней заполнены. ✓ |
| Mission alignment | Миссия системы (помогать Claude доводить до качества дёшево) совпадает с миссией каждого компонента. ✓ |
| Concept clarity | Явно сказано, что НЕ есть (не CI, не семантика, не AI-ревьюер). ✓ |
| Values → Skills | V1 (механика) → S1, S2, S9. V2 (дешёвое впереди) → S5, триаж. V3 → diff-only. V4 → cache-friendly. V5 → S8. V6 → объяснимые stderr. V7 → bypass + skip-list. V8 → AGENTS.md override. ✓ |
| Skills → Behaviors | S1 → B1. S2 → B2, B5. S3 → B3, B6. S4 → B4. S5 → встроено в B3. S6 → B6. S7 → B8. S8 → B7. S9 → B7. S10 → B4. S11 → B5. ✓ |
| Behaviors → Environment | Все сценарии обеспечены файлами/зависимостями из L1. ✓ |
| Cross-level coherence | Skill «fdr-runner» (S3) обслуживает поведение B3, которое реализует ценность V2 (дешёвое впереди), которая поддерживает миссию (минимум токенов). Без orphan'ов. ✓ |

---

## 13. Дальнейшие версии (out of scope для v1)

- v1.1: TUI-просмотрщик `fdr-<sid>.md` для удобства ревизии человеком.
- v1.2: метрики usage, экспорт в Grafana / простой dashboard.
- v1.3: cross-session аналитика — какие категории findings повторяются, паттерны лени.
- v2.0: проектные оверрайды через `.claude/strict-mode.json` (per-repo).
- v2.1: интеграция с pre-commit hooks Git (двойная страховка).

---

## 14. Implementation log

### Wave 1 — token economy quick wins (deployed 2026-04-29)
- `prune-mem.py` написан, `claude-mem-context` подрезан в обоих CLAUDE.md.
- `~/.claude/CLAUDE.md` переписан на EN slim с RU output policy.
- Эффект: −2000 токенов на каждом турне.

### Wave 2 — foundation hooks (deployed 2026-04-29)
- 6 хук-скриптов: `health-check.sh`, `prompt-inject.sh`, `pre-write-scan.sh`, `record-edit.sh`, `stop-guard.sh`, `stub-scan.sh`.
- `settings.json` обновлён, hooks block активен с timeouts.
- `enhanced-code-review` SKILL.md — триггеры обрезаны под `/fdr-deep` (раньше «Параллельная задача» в §6 Phase 1, теперь сделано).
- 38/38 unit-тестов в `~/.claude/hooks/tests/run-tests.sh`.
- Phase 1 + частичная Phase 7 спеки.

### Wave 2.5 — honesty challenge addon (deployed 2026-05-03)
- `~/.claude/hooks/fdr-challenge.sh` добавлен в Stop chain после `stop-guard.sh`.
- Триггер: verdict-pattern + FDR-context narrowing + per-session one-shot.
- Без артефакт-гейта (Wave 3).
- 66/66 тестов pass.

### Wave 2.5 fixes (closed cascading findings):
- **F26**: `stub-scan.sh` file-mode больше не загружает в bash-var, грежет напрямую (-25..100× латентность).
- **F27**: `pre-write-scan.sh` skip при content > 512KB (env `STRICT_PRE_WRITE_MAX_BYTES`).
- **N20**: `tail -n` увеличено с 50 до 200 для покрытия progress-записей в JSONL.
- **N21**: subagent detection через `/subagents/` в transcript_path как fallback к `hook_event_name`.
- **N22**: формат транскрипта верифицирован против реального Claude Code (`message.content` array of `{type:"text",text:...}`).
- **N23**: `stop-guard.log` запись при fire — покрыто тестом.
- **N24**: markdown code-blocks вырезаются перед verdict-scan через awk (известная false-negative trade-off задокументирована в коде).
- **N25**: end-to-end positive — challenge сработал в живой сессии 2026-05-03.
- **F50**: claude-mem plugin overlap audited, no harmful conflicts.

### Wave 2.5+ enhancements (deployed 2026-05-03, beyond original spec)

После недели эксплуатации Wave 2.5 в живой работе выявлено 5 классов проблем — все закрыты. Тестов: 149/149.

- **E1 — Reason refactor (no-tables policy):** cycle 0/N reason'ы переписаны с императивов «продолжай ФДР→fix→правь код» вместо требования 9-layer таблицы coverage. Старая формулировка индуцировала длинные ответы-отчёты вместо реальной работы. Reminder #2 переформулирован: «9 FDR layers internally — NO 9-layer coverage table in chat».

- **E2 — Meta-bypass через magic-string:** агент может ответить буквально `meta-discussion, no FDR work` (≤300 chars) — хук пропускает Stop. Защиты: (a) работает только если `EDITS_IN_TURN==0` (нет реальных правок в текущем турне через jq-счётчик `tool_use` Edit/Write/MultiEdit); (b) length-check ≤300 chars отсекает цитаты в длинных сообщениях. Реализация: `fdr-challenge.sh` cycle 0 + cycle N branches, log action `allow-self-meta`. Закрывает кейс «обсуждаем дизайн хука, цитируем `0 проблем`, хук file'ится» — agent сам объявляет meta вместо ручного `bypass-<sid>` файла.

- **E3 — Missing-verdict trigger:** если в текущем турне БЫЛИ code edits AND есть FDR-context, но финальное сообщение НЕ содержит verdict-фразы → block с reason «дай verdict (`0 проблем`+rationale OR list of findings)». Закрывает паттерн «отчитался про round-N fixes и убежал без verdict». Hash-tracking namespace `m:` (отделён от `v:` verdict-trigger). Reminder #6: «After code edits final message MUST contain explicit verdict».

- **E4 — Verdict-with-rationale requirement:** judge prompt теперь требует rationale для `0 проблем` (1-3 sentences naming concrete checked items) — bare verdict классифицируется как `evasive`. Иначе модель могла бы ответить голым «0 проблем» каждый раз и judge принимал бы как complete. Reminder #6 это формализует. `complete` = либо list of findings (file:symbol+severity), либо `0 проблем`+rationale.

- **E5 — Recursion guard (CRITICAL):** **корневая причина** почему ВСЕ challenge'и до этого фикса шли в silent allow. `judge.sh` запускает `claude -p` для классификации → headless claude получает наш `UserPromptSubmit` reminder включая правило #7 (magic-string self-bypass) → Haiku **сама** отвечала `meta-discussion, no FDR work` вместо JSON. Парсер видел не-JSON → fallback `unknown` → silent allow. Фикс: env-флаг `STRICT_MODE_NESTED=1` экспортируется при `claude -p` вызове, ВСЕ 6 хуков (prompt-inject, fdr-challenge, stop-guard, health-check, pre-write-scan, record-edit) skip при флаге.

- **E6 — Judge prompt syntax fix (CRITICAL):** старый `PROMPT="..."` в judge.sh содержал литералы `"no impact / not in scope"` (двойные кавычки внутри двойных) и `weren't` (одинарный апостроф) — bash интерпретировал как command + unmatched quote → `impact: command not found` → `set -u` падал на `PROMPT: unbound variable` → claude вообще не вызывался. Все «judge unknown» в логах ДО E5/E6 — последствия этого, не auth/network. Фикс: quoted heredoc + placeholder substitution (`${PROMPT_TEMPLATE//__HISTORY_PLACEHOLDER__/$HISTORY}`).

- **E7 — Diagnostic logging:** `judge.sh` теперь дампит stderr+stdout+prompt-size в `~/.claude/state/judge-stderr.log` при exit≠0. `fdr-challenge.sh` добавляет в `stop-guard.log` extra-поля: `matched: <pattern>`, `extracted_from_ts`, `lag_minutes`, `transcript_last_ts` (для race-detection). Read-delay 2000ms (override `STRICT_HOOK_READ_DELAY_MS`).

- **E8 — gtimeout dependency:** `brew install coreutils` обязателен на macOS. Без него `claude -p` без timeout-обёртки может зависнуть. `judge.sh` использует `timeout 50` (10s buffer ниже Stop hook timeout 60000ms). Health-check warning'ует если отсутствует.

## 15. Wave 3 design amendments (после FDR)

### 15.1 Wave 2.5 + Wave 3 hook integration

`fdr-challenge.sh` (Wave 2.5) и расширенный `stop-guard.sh` (Wave 3 артефакт-гейт) оба сидят в Stop chain. Поведение при одновременном срабатывании:

**Order:** stop-guard.sh ПЕРВЫМ (fail-fast on stubs/missing-artifact), fdr-challenge.sh ВТОРЫМ (honesty layer поверх артефакта).

**Critical: bundle-agents are subagents** — их output (`0 problems` clean response per §4.2.3 contract) НЕ должен триггерить fdr-challenge. fdr-challenge.sh ALREADY skips on SubagentStop event и `/subagents/` path в transcript_path (см. fdr-challenge.sh begin-of-script checks). Wave 3 implementation обязан сохранить этот skip — иначе каждый bundle-agent с clean verdict ломает /fdr.

**Sensitive verifier + challenge — двойной layer:** sensitive-path detected → stop-guard запускает fdr-verify.sh (Wave 3) → потом fdr-challenge fires. Это by-design: verifier даёт structural check, challenge — honesty check. Оба независимы, оба полезны. Reasons aggregate в Stop reason text.

**Mtime-based mechanisms — конфликт-разбор:** в системе НЕСКОЛЬКО mtime-based триггеров на разных файлах:
- Wave 2.5 fdr-cycles-<sid>.jsonl mtime > 30 мин → stale-reset (`fdr-challenge.sh`)
- Wave 3 edits-<sid>.log mtime vs fdr-<sid>.md mtime → recheck-trigger (`stop-guard.sh`)
- Wave 3 prepass-<sid>-*.log.lock mtime > 60 мин → stale-cleanup (`state-cleanup.sh`)

**Конфликта нет** потому что каждый mechanism смотрит на **РАЗНЫЕ файлы**:
- fdr-cycles.jsonl — Wave 2.5 cycle counter
- fdr-<sid>.md vs edits-<sid>.log — Wave 3 artifact-vs-edits
- prepass-*.lock — Wave 3 prepass coordination

Один и тот же файл НЕ читается двумя mechanism'ами. Race condition'ы между ними отсутствуют.

**Каскадный сценарий, который надо знать:** /fdr пишет артефакт → mtime artifact = T0. Пользователь правит файлы → edits-log updates → mtime edits-log = T1 > T0. Stop fires → stop-guard видит artifact + open findings + edits-log freshter → auto-block recheck. Параллельно fdr-cycles.jsonl мог быть от challenge'а ранее (если был), его mtime тоже обновится через challenge cycle если /fdr-recheck вызовет judge. Эти потоки не пересекаются.

**Decision aggregation (per Claude Code docs):** если ЛЮБОЙ хук вернул `decision:"block"` — Stop блокируется. Reasons из всех block'ующих хуков concatenate'ятся (с разделителем `\n---\n`).

**Сценарии:**
- Edits + нет артефакта + verdict-фраза «0 проблем»: stop-guard блок «run /fdr», fdr-challenge fires (cycle 0). User видит оба reason'а. Действие: запустить /fdr → артефакт пишется → следующий Stop: stop-guard pass, fdr-challenge cycle 1 (judge классифицирует ответ).
- Edits + валидный артефакт + verdict «0 проблем»: stop-guard pass, fdr-challenge может fire (если не fired в этой сессии). Норма.
- Recheck cycle (cycles ≥ 2): stop-guard pass (артефакт valid), fdr-challenge skip (cycles>1 — already in iteration, not initial verdict).

### 15.2 Wave 3 permissions

Phase 3 деплой требует `~/.claude/settings.json:permissions.allow` содержит `"Skill(*)"` (для Skill tool вызова `/fdr`) и `"Agent(*)"` (для bundle-agent invocation). Если allow-list не содержит — модели придётся запрашивать разрешение, что ломает «automatic» сценарий.

```bash
# Добавить через python merge:
python3 -c "import json; from pathlib import Path; p=Path.home()/'.claude/settings.json'; s=json.loads(p.read_text()); a=s.setdefault('permissions',{}).setdefault('allow',[]); [a.append(x) for x in ['Skill(*)','Agent(*)'] if x not in a]; p.write_text(json.dumps(s,indent=2,ensure_ascii=False))"
```

### 15.3 Mock infrastructure для Agent tool

**Архитектурный nuance:** env vars работают для shell-скриптов (judge.sh, fdr-verify.sh — `claude -p` вызовы из bash). Но bundle-agents в /fdr — это вызовы `Agent` tool из skill body, которое исполняется моделью. Env vars недоступны как переменные внутри model's tool_use генерации.

**Что мокается полноценно (env vars, надёжно):**
- `STRICT_JUDGE_MOCK_RESPONSE` (Wave 2.5) — `judge.sh` (shell)
- `STRICT_VERIFIER_MOCK_RESPONSE` — `fdr-verify.sh` (shell, headless `claude -p`)
- `STRICT_TRIAGE_MOCK_RESPONSE` — если триаж выносится в `triage.sh` (shell wrapper над `claude -p`)

**Что НЕ мокается надёжно — Agent tool calls из skill body:**

Bundle agents в /fdr skill body — это вызовы Claude Code `Agent` tool из инструкции модели. Env vars недоступны как переменные внутри model context. Conditional «if test-mode file exists, read mock instead of Agent» в skill body — это ИНСТРУКЦИЯ, которой модель может не следовать строго (особенно под нагрузкой). **Это известное ограничение:** end-to-end test для /fdr невозможен без harness-level support от Claude Code.

**Mitigation strategies (несовершенные, но используемые):**
1. **Триаж и verifier — выносить в shell-скрипты** (`triage.sh`, `fdr-verify.sh`) вместо Agent calls. Shell поддерживает env-mock. Bundle agents придётся оставить как Agent calls.
2. **Тестировать components изолированно:** валидатор артефакта (fdr-validate.sh, чистый shell) с pre-seeded артефактами; static-prepass.sh — с mock-аналайзерами (fake phpstan).
3. **Bundle agents — manual integration testing** на реальных задачах. Принимаем что unit-тестов на них не будет.
4. **Документировать в Phase 9 (replacement):** «Wave 3 verification = manual smoke на 3 эталонных задачах, automated tests только для shell-компонентов».

Test fixtures: `~/.claude/hooks/tests/fixtures/wave3/{triage,verifier,validator,prepass}/*.json` — для shell-mockable компонентов. Bundle-agents fixtures — `bundle-A-expected-output.txt` для manual validation что output format соответствует contract'у.

### 15.4 Cost forecast Wave 3 (per /fdr run)

| Component | Model | Per call | Per /fdr |
|-----------|-------|----------|----------|
| Triage | Haiku 4.5 | ~$0.001 | 1× |
| Bundle agents (×4) | Sonnet 4.6 | ~$0.05–0.20 | 4× = $0.20–$0.80 |
| Recheck | Haiku 4.5 | ~$0.001 | 1× per cycle |
| Verifier (sensitive only) | Sonnet 4.6 | ~$0.05–0.10 | conditional |
| Judge (Wave 2.5 dependency) | Haiku 4.5 | ~$0.001-0.003 | per challenge cycle |

**Estimated total per /fdr:** $0.20–$1.00 (depending on scope size + sensitive-path).
**On 5 /fdr per day:** $1–$5/day = **$30–$150/month**.
**Failsafe cap 10 cycles:** worst case $2–$10 per stuck cycle (rare).

**Anti-stall mechanism (per Wave 2.5 lesson):** failsafe cap=10 защищает от runaway, но даёт дорогую failure mode. Дополнительно:
- /fdr runner сравнивает hash артефакта current cycle vs previous cycle. Если 2 цикла подряд дают идентичный hash artifact (same scope, same findings, same verdict) → considered «stalled, no progress», allow Stop с warning «FDR не сходится, manual review нужен» вместо продолжения до cap.
- Hash хранится в `~/.claude/state/fdr-cycle-hash-<sid>.log` (append per cycle).
- Сравнение в /fdr skill body перед инкрементом cycles counter.
- Защищает от cost-spike runaway сценариев (2 cycle = $0.4-2 max вместо 10 cycle = $2-10).

Decision: при включении Wave 3 в production — мониторить через `/cost` Claude Code еженедельно. Если spike > $200/month — ревизия (cap уменьшить, sensitive-paths сузить, opt-in для крупных проектов через env flag).

### 15.5 Cross-cutting clarifications (LOW finding fixes)

**Verifier «5 issues» limit (F15):** число обосновано — verifier фокусируется на CRITICAL gaps, не на полном пере-FDR. Если 5 — сигнал «main reviewer halturil», escalation тревога. Магия не в 5 как таковом, а в верхней границе focused review.

**`/fdr-deep` semantics (F16):** существующий `enhanced-code-review` skill — это **9 отдельных subagents** (по агенту на каждый layer 1-9), full-depth ревью с 7-vector cross-file проверками. `/fdr` (Wave 3 default) — **4 bundle agents**, layers свёрнуты в bundles A/B/C/D, до 50% дешевле. `/fdr-deep` для критичных правок (auth, payment, миграции с массовыми данными) когда нужна максимальная глубина за дополнительные $0.30-1.

**Model id pinning (F13):** spec фиксирует exact model ids (`claude-haiku-4-5-20251001`, `claude-sonnet-4-6`). При deprecation Anthropic'ом — все скрипты надо обновлять централизованно. Предлагается константа `STRICT_HAIKU_MODEL` в `~/.claude/hooks/lib/models.sh` (sourced каждым hook), default обновляется в одном месте.

**State representation (F17):** Wave 2.5 `fdr-cycles-<sid>.jsonl` (append JSONL, machine-readable history) и Wave 3 `fdr-<sid>.md` (markdown artifact, human + LLM readable) — разные roles. JSONL для cycle-counter и judge-classification metadata. Markdown для FDR-результата с findings. Не дублируют, complement друг друга.

**Test fixtures (F14):** install.sh должен создать каталог `~/.claude/hooks/tests/fixtures/wave3/{triage,bundle-a,bundle-b,bundle-c,bundle-d,verifier}/` (пустой для Wave 1+2+2.5 install). При активации Wave 3 — bundle/templates/wave3-fixtures/ копируется туда.

**Wave 3 permissions deferred (F10):** install.sh **НЕ должен** добавлять `Skill(*)` и `Agent(*)` в permissions.allow при Wave 1+2+2.5-only deploy. Эти permissions добавляются отдельной командой `bash install.sh --enable-wave3` когда /fdr skill реально deploy'ится.

### 15.6 Wave 3 rollback

**Все rollback-команды идемпотентны** — `rm -f` (не падает если файл отсутствует), `python3` script с `pop(..., None)` (не падает если ключ отсутствует), `if [[ -f ]]` guards. Phase rollback можно вызвать на не-инсталлированной phase — выполнится no-op.

**Phase 3 (runner skill):** удалить `~/.claude/skills/fdr/SKILL.md` (rm -f). Wave 2.5 продолжит работать (challenge без runner).

**Phase 2 (artifact-gate в stop-guard):**
```bash
cp ~/.claude/backups/stop-guard.sh.bak-wave3 ~/.claude/hooks/stop-guard.sh
```
Восстанавливает Wave 2 минимальный stop-guard (только stub-detection).

**Phase 4 (static prepass):** убрать `static-prepass.sh` из PostToolUse в settings.json. Аналайзеры перестанут запускаться, остальное не задето.

**Phase 5 (sensitive verifier):** убрать `is-sensitive.sh` invocation из stop-guard.sh. fdr-verify.sh остаётся файлом, но не вызывается.

**Полный откат Wave 3:**
```bash
cp ~/.claude/backups/{settings.json,stop-guard.sh}.bak-wave3 ~/.claude/{settings.json,hooks/stop-guard.sh}
rm ~/.claude/skills/fdr/SKILL.md ~/.claude/hooks/{static-prepass.sh,fdr-verify.sh,is-sensitive.sh,is-trivial-diff.sh,fdr-validate.sh}
```
Wave 2.5 + Wave 2 + Wave 1 продолжают работать как раньше.

---

### Wave 3 — pending (design-FDR'd 2026-05-03)
- Compoenents: `/fdr` skill, `fdr-validate.sh`, артефакт-гейт в `stop-guard.sh`, headless verifier для sensitive-paths, static-prepass.
- **FDR pre-implementation выполнен**: 25 findings (5 HIGH + 8 MEDIUM + 12 LOW) — все закрыты в спеке (§15 amendments + точечные правки в §3-§7).
- HIGH-фиксы: runner.sh контракт уточнён, orphan-edits timestamp source через session-start файл, base-ref для git diff = HEAD, prepass naming через sanitized full path, triage error fallback.
- MEDIUM-фиксы: verifier comparison file/symbol-aware, re-check trigger 3-tier, Verdict канонический формат, static-analyzer security warning, Wave 2.5+3 integration, mock infrastructure через env vars, trivial-handling single source, Wave 3 permissions.
- LOW-фиксы: typo «5 полей»→7, vacuous-truth в C7, orphan guard, verifier verdict format, pending fix-commit, auth-failure path, Phase 2/6 acceptance criteria, cache TTL caveat.
- Не активирован — следующий шаг implementation по фазам §6.
