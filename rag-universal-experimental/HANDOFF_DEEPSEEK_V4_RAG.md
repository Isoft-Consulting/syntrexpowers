# RAG Handoff For DeepSeek v4

## 1. Mission

Твоя задача: продовжити прокачку локального RAG-сервера в `/var/www/core/.mcp/rag-server` так, щоб:

- пошук на реальних code-review / implementation / frontend / cross-file задачах був максимально точним;
- downstream reading cost по токенах залишався мінімальним;
- runtime був стабільним на великому живому індексі;
- latency search-path була суттєво кращою, ніж зараз;
- всі покращення були безкоштовними, без платних reranker/embedding API;
- не ламались уже існуючі real-world regression corpora.

Поточний головний bottleneck уже не в базовій якості retrieval, а в runtime latency і в окремих слабких query-класах.

## 2. Critical Constraints

- Не коміть і не пуш нічого, якщо власник прямо не попросить.
- Не роби branch switching / нові гілки.
- `.rag-index/` — локальний runtime artifact, не для git.
- Перед великим аналізом/змінами користуйся локальним RAG, а не лише `rg`.
- Після кожного change-set обов'язково роби deterministic verification і FDR до `0 проблем`.
- Не використовуй destructive git commands.

## 3. Canonical Source Of Truth

### Runtime / implementation

- `/.mcp/rag-server/rag_universal/core.py`
- `/.mcp/rag-server/rag_universal/eval_quality.py`
- `/.mcp/rag-server/rag_universal/cli.py`
- `/.mcp/rag-server/rag_universal/mcp_server.py`

### Tests / verification

- `/.mcp/rag-server/tests/test_rag_universal.py`
- `/.mcp/rag-server/tests/run-tests.sh`

### Config / ops contract

- `/.mcp/rag-server/rag.config.json`
- `/.mcp/rag-server/README.md`
- `/.mcp/rag-server/AGENT_INSTALL.md`

### Real evaluation corpora

- `/.mcp/rag-server/evals/core-leonextra-fresh-merged-prs-v1.json`
- `/.mcp/rag-server/evals/core-leonextra-fresh-frontend-prs-v1.json`

### Historical evidence / context

- `/.mcp/rag-server/reports/core-fdr-rag-vs-baseline.md`

## 4. Current State Summary

На момент handoff RAG уже суттєво прокачаний.

### 4.1. Retrieval quality

На real merged PR corpora раніше був досягнутий та неодноразово підтверджувався такий рівень:

- backend corpus:
  - `Top-1: 10/10`
  - `Top-3: 10/10`
  - `MRR: 1.0`
- frontend corpus:
  - `Top-1: 8/8`
  - `Top-3: 8/8`
  - `MRR: 1.0`

Це важливо: ці результати були не на synthetic-only тестах, а на real review-comments з merged PR.

### 4.2. Token economy

RAG уже давав дуже сильну економію evidence budget порівняно з keyword-only baseline:

- frontend baseline без RAG міг тягнути сотні тисяч “оцінених evidence tokens”;
- RAG стискав це до сотень / низьких тисяч.

Тобто по token economy система вже хороша.

### 4.3. Runtime / latency

Головна проблема зараз:

- latency на великому живому індексі все ще занадто висока;
- повні `benchmark-quality` на real corpora можуть бути дуже довгими;
- особливо важкий `frontend` path.

### 4.4. Reliability

Окремий reliability-прохід уже зроблений:

- bad/corrupt `search.sqlite` тепер перевіряється через `PRAGMA quick_check`;
- `search_index()` уміє repair-path через локальний rebuild лише `search.sqlite`;
- `benchmark_quality()` спочатку пробує repair search cache, а full rebuild робить лише як fallback;
- regression tests на corrupt sqlite вже додані.

## 5. What Has Already Been Implemented

Нижче ключові покращення, які вже існують. Не дублюй їх повторно без потреби.

### 5.1. Retrieval / ranking

- self-RAG implementation priority;
- `review_comment` retrieval profile;
- frontend-specific decomposition/fusion;
- broader review-comment heuristics;
- noise suppression for docs / tests / devtools false positives;
- lexicon side-index через sqlite table;
- query role bias;
- section anchor aware rerank;
- consumer-aware read-plan ordering;
- confidence-aware read plan;
- frontend result shaping;
- chunk role labeling.

### 5.2. Indexing / search cache

- incremental reindex;
- sqlite search cache;
- sqlite lexicon table;
- BM25 batching;
- per-search cache for BM25 token rows;
- per-search cache for path/lexicon lookups;
- `search.sqlite` integrity checks and auto-repair path.

### 5.3. Benchmark / quality harness

- `benchmark-quality` CLI;
- latency avg / p50 / p95 metrics;
- tokens avg / p50 / p95 metrics;
- verdict thresholds;
- mode-aware benchmark profiles;
- benchmark profiles configurable from `rag.config.json`.

### 5.4. Config / corpus

- root-level `rag.config.json` already moved into `/.mcp/rag-server/rag.config.json`;
- `.ai-review/**` excluded from index;
- `.vue/.jsx/.tsx` indexing enabled;
- real corpora for fresh backend/frontend merged PRs added.

## 6. Current Real Weak Spots

Це головне, з чим тобі треба працювати далі.

### 6.1. High latency on live big repo

Найбільша проблема зараз.

Симптоми:

- `search_index_with_plan()` на живому індексі відчутно довгий;
- `benchmark-quality` на full real corpus може працювати дуже довго;
- frontend cases важчі за backend;
- навіть точкові real searches на великому індексі можуть бути занадто повільними.

### 6.2. Weak query class: spec/cross-cutting/error-code findings

Приклад:

- review про `cursor_query_mismatch`, HMAC cursor mismatch, `ErrorCode` / enum / controller / spec-heavy finding.

Проблема:

- RAG не локалізував target жорстко;
- правильний кодовий контур знаходився не в top-1;
- finding змішував spec refs + runtime behavior + missing/shifted path.

Тут треба окреме retrieval treatment.

### 6.3. Weak query class: frontend schema/redirect/template flow findings

Приклад:

- review про `create.yaml`, `InterfaceView.vue`, `redirect`, `result.workbook_id`, `core_http_bridge`.

Проблема:

- RAG пішов у feature components DT3 замість точного попадання в schema + `InterfaceView.vue`.

Тут теж потрібен окремий targeted retrieval improvement.

### 6.4. Benchmark runtime cost

Навіть коли quality хороша, сам benchmark harness дорогий на великому індексі.

Ймовірні джерела:

- repeated full-path searches per case;
- expensive baseline token estimation;
- heavy read-plan/token estimation;
- no dedicated micro-profiler around the slowest loops;
- costly frontend decomposition/fusion on every relevant case.

## 7. Recent Important Findings From Real Review Prose

Це важливо як орієнтир для future tuning.

### 7.1. Review case: OwnerV2 audit chain

Review findings про:

- `verifyChainIntegrity`
- `computeEntryHash`

RAG quality:

- good;
- `OwnerAuditChainRepository.php` підіймався як `top-1`.

### 7.2. Review case: `cursor_query_mismatch`

RAG quality:

- weak;
- query class spec-heavy / enum-heavy / cross-cutting;
- top hits ішли в менш релевантні controllers / unrelated paths.

### 7.3. Review case: DT3 viewer vs BFF gate

RAG quality:

- good;
- `AdminPluginProxyController.php` був `top-1`.

### 7.4. Review case: DT3 create redirect

RAG quality:

- weak;
- top hits ішли в DT3 Vue components, а не в `create.yaml` + `InterfaceView.vue`.

## 8. What To Do Next

Пріоритети нижче впорядковані за реальним ROI.

### Priority 1: Latency profiling and reduction

Це зараз найважливіше.

Треба:

1. Додати детальний local profiler around:
   - `search_index_with_plan()`
   - `search_index()`
   - `search_precomputed_cache()`
   - frontend decomposition/fusion branch
   - benchmark case loop in `benchmark_quality()`
2. Виміряти окремо:
   - tokenization/query prep
   - sqlite fetch
   - BM25 scoring
   - lexicon/path candidate fetch
   - rerank/select path
   - read_plan build
   - token estimation
3. Знайти саме p95 contributors, а не просто “середнє повільно”.

Expected outcome:

- зрозуміти, які 1-2 функції реально дають основний latency tail.

### Priority 2: Better retrieval for spec/error-code/cross-cutting findings

Цільовий клас:

- `ErrorCode`
- `Errors`
- `cursor_*`
- `query_hash`
- `path drift`
- `HMAC mismatch`
- `enum/controller/spec` змішані review comments.

Що робити:

1. Додати окремий query profile для `spec_cross_cutting` / `error_code_review`.
2. Підсилити:
   - enum files
   - `ErrorCode`-like paths/names
   - controller code with exact error literals
   - spec-like anchor extraction (`§6`, `§11`, `§16`) як secondary hint, не як primary target
3. Даунранкати generic controllers, якщо є точні literal/code anchors.
4. Додати regression cases під цей клас.

### Priority 3: Better retrieval for schema redirect/template flow findings

Цільовий клас:

- YAML schema
- `InterfaceView.vue`
- redirect/template interpolation
- `result.*`
- `core_http_bridge`
- `submit.create/update`

Що робити:

1. Додати query profile для `schema_flow_review`.
2. Boost:
   - `schemas/**/*.yaml`
   - `InterfaceView.vue`
   - `resolveTemplate`
   - `redirect`
   - `submit`
   - `result.<field>`
3. У frontend review-comment mode:
   - сильніше пов'язати `schema + renderer/view` pair retrieval
   - не віддавати першим feature components, якщо query містить `redirect`, `template`, `create.yaml`, `result.workbook_id`
4. Додати real regression cases.

### Priority 4: Benchmark harness optimization

Коли зрозумієш головні latency hotspots, оптимізуй benchmark-path.

Можливі кроки:

- cache per-case derived query artifacts;
- avoid repeated heavy baseline token reads;
- faster evidence token estimation;
- optional “fast benchmark” mode for changed query class only;
- explicit corpus sharding by profile.

### Priority 5: Expand real corpora

Потрібно зібрати ще більше реальних review-comment cases, особливо:

- spec-heavy findings;
- frontend schema/view flow findings;
- authorization/role mismatch findings;
- controller + route policy mismatch findings;
- response shape / redirect / unwrap mismatches.

Нові corpora важливіші за ще одну випадкову heuristic.

## 9. What Not To Do

- Не тащи платный external reranker.
- Не добавляй LLM rewrite на каждый query.
- Не делай massive AST-heavy rewrite всего indexer без profiler evidence.
- Не ухудшай current backend/frontend real corpora ради одной красивой heuristic.
- Не оптимизируй вслепую без измерений.

## 10. Exact Tools And Commands To Use

### 10.1. Main CLI

Базовые команды:

```bash
python3 .mcp/rag-server/tools/rag.py status --root .
python3 .mcp/rag-server/tools/rag.py index --root . --incremental
python3 .mcp/rag-server/tools/rag.py search --root . --mode implementation --top-k 5 --with-plan "your query"
python3 .mcp/rag-server/tools/rag.py search --root . --mode frontend --top-k 5 --with-plan "your query"
python3 .mcp/rag-server/tools/rag.py benchmark-quality --root . --cases .mcp/rag-server/evals/core-leonextra-fresh-merged-prs-v1.json --mode implementation --profile auto --summary-only
python3 .mcp/rag-server/tools/rag.py benchmark-quality --root . --cases .mcp/rag-server/evals/core-leonextra-fresh-frontend-prs-v1.json --mode frontend --profile auto --summary-only
```

### 10.2. Deterministic verification

```bash
cd .mcp/rag-server
./tests/run-tests.sh

python3 -m py_compile \
  .mcp/rag-server/rag_universal/core.py \
  .mcp/rag-server/rag_universal/eval_quality.py \
  .mcp/rag-server/rag_universal/cli.py \
  .mcp/rag-server/tests/test_rag_universal.py

git diff --check
```

### 10.3. Useful repo search

Prefer:

```bash
rg --files
rg -n "pattern" path/
```

### 10.4. Process hygiene

У попередній сесії було багато long-running exec processes, і це заважало benchmark/index.

Перед довгими замірами:

```bash
ps -eo pid,etimes,cmd | rg "rag.py|benchmark-quality|index --root"
```

Якщо зависли старі benchmark/index processes, прибери тільки їх, а не все підряд:

```bash
kill <pid1> <pid2> ...
```

## 11. Recommended Working Loop

Для кожної ітерації роби так:

1. `rag.py status --root .`
2. Якщо `stale=true`:
   - `rag.py index --root . --incremental`
3. Запусти 2 типи замірів:
   - targeted live searches по конкретному weak query class
   - relevant `benchmark-quality` на corpus
4. Внеси зміни.
5. Запусти:
   - `./tests/run-tests.sh`
   - `py_compile`
   - `git diff --check`
6. Повтори live search.
7. Повтори benchmark.
8. Зроби FDR по change contour.

## 12. Immediate Suggested Task Plan

Ось конкретний план, з якого краще почати.

### Step A. Stabilize measurement

- очисти/убери старые зависшие `rag.py benchmark-quality` и `rag.py index` процессы;
- добейся, чтобы `rag.py status --root .` стабильно возвращал `stale=false`;
- зафиксируй baseline latency по:
  - одному backend real query
  - одному frontend redirect/template query
  - одному spec/error-code query

### Step B. Add micro-profiling

- instrument `search_index_with_plan()` and `search_precomputed_cache()` с phase timings;
- instrument `benchmark_quality()` per-case timings.

### Step C. Fix one weak class at a time

Сначала:

- `schema_flow_review`

Потом:

- `spec_cross_cutting/error_code_review`

### Step D. Re-run real-world proof

Проверь минимум:

- existing backend corpus
- existing frontend corpus
- one manual review prose for schema redirect
- one manual review prose for cursor/error-code mismatch

## 13. Verified Facts To Keep In Mind

- `uier/app/Http/Controllers/AdminPluginProxyController.php` уже содержит `viewer` в `RUNTIME_ROLES`.
- `plugins/data-tables-3/schemas/workbooks/create.yaml` уже использует `{{result.workbook_id}}`.
- `uier-spa/src/tests/views/InterfaceView.test.ts` уже содержит redirect test через response data.
- `OwnerAuditChainRepository.php` остаётся хорошим real target для audit-chain findings.
- `Cursor.php` использует `cursor_invalid`, а не `cursor_query_mismatch`.
- файла `app/Domain/ControlPlane/OwnerV2/Enums/ErrorCode.php` в текущем checkout нет.

Це важливо, бо частина review-текстів, які ви будете проганяти через RAG, може бути вже історично застарілою. Треба відрізняти:

- `RAG знайшов правильний кодовий контур`
- від
- `сам finding ще актуальний у поточному checkout`

## 14. Success Criteria

Твою наступну хвилю покращень можна вважати успішною, якщо:

1. current real corpora не просіли по `Top-1`, `Top-3`, `MRR`;
2. weak review classes стали локалізуватися краще;
3. `benchmark-quality` на живому індексі став відчутно швидшим;
4. runtime не деградував через `search.sqlite`;
5. усі нові зміни покриті regression tests;
6. `./tests/run-tests.sh`, `py_compile`, `git diff --check` — зелені.

## 15. Short Executive Summary

Якщо дуже коротко:

- quality RAG вже хороша;
- token economy вже дуже хороша;
- reliability search cache стала кращою;
- головний remaining problem — latency;
- головні weak retrieval classes:
  - spec/error-code/cross-cutting findings
  - frontend schema/redirect/template flow findings

Починай не з нових “магічних” heuristics, а з profiler-first підходу і targeted improvements по цих двох weak classes.
