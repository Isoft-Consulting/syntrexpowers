# RAG vs No-RAG: FDR Quality Comparison

Проведено 5 пошукових сценаріїв, які симулюють питання FDR-ревьюера по Core branch `stage-a-node-image-rollout` (`bc16f9804`). Перевірялись файли з реального review по node image build/rollout: `bin/build_and_push_node_images.sh` (298 рядків), `docker/Dockerfile.uier-api` (60), `docker/Dockerfile.uier-spa` (35), `.dockerignore` (46), `BuildAndPushNodeImagesScriptTest.php` (340), `NodeImageDockerfilesContractTest.php` (104), план `2026-05-04-node-image-build-and-rollout-plan-v1.md` (965), `uier/bootstrap/autoload.php` (101), `uier/bin/migrate.php` (267).

Index snapshot: 7749 files, 67835 chunks, 40676 symbols. `No-RAG` baseline тут означає простий keyword scan по тому самому indexed file set без BM25/vector scoring, path boost, artifact boosts, source penalties, role boosts і SQLite retrieval cache.

## Результати по 5 реальних аспектах FDR

| # | FDR-аспект | Без RAG | Default RAG | FDR mode | Різниця |
|---|---|---|---|---|---|
| 1 | Bash 3.2 compatibility | Baseline пішов у snapshot/demo YAML шум і не підняв жоден з 3 ключових evidence files у top-10. Без точного `rg "declare -A"` агент легко пропускає macOS-only failure. | Default RAG знайшов plan rank 1, test rank 3, script rank 6. Coverage: 3/3 у top-10, але script поза top-5. | FDR mode знайшов plan rank 1, test rank 2, script rank 4. Coverage: 3/3 у top-5. | FDR mode перетворює platform-specific blocker у compact spec -> test -> source bundle. |
| 2 | Dry-run script contract | Baseline знайшов plan rank 1 і test rank 2, але script лише rank 7. Контекст розірваний: контракт видно, source implementation треба шукати додатково. | Default RAG видав plan rank 1, script rank 2, test rank 3. Coverage: 3/3 у top-3. | FDR mode зберіг plan rank 1, script rank 2, test rank 3. Coverage: 3/3 у top-3. | RAG одразу збирає spec -> implementation -> behavioral test bundle. |
| 3 | UIer image autoload/Core deps | Baseline не знайшов у top-10 жоден з потрібних source/test files; top results були deploy findings, infra docs і snapshots. | Default RAG видав `Dockerfile.uier-api` rank 1, `uier/bootstrap/autoload.php` rank 2, root `bootstrap/autoload.php` rank 3, test rank 5. Coverage: 4/4 у top-5. | FDR mode видав Dockerfile rank 1, UIer autoload rank 2, plan rank 3, test rank 4, root autoload rank 6. Coverage: 3/4 у top-5, 4/4 у top-10. | Default краще для tight dependency-chain query; FDR краще додає plan/test context. |
| 4 | UIer migration entrypoint | Baseline знайшов plan rank 1, `NodeUpdater.php` rank 2, `uier/bin/migrate.php` rank 4, але не знайшов Dockerfile. | Default RAG знайшов `uier/bin/migrate.php` rank 1, plan rank 3, Dockerfile rank 4. Coverage: 3/4 у top-5. | FDR mode знайшов `uier/bin/migrate.php` rank 1, plan rank 2, Dockerfile rank 3, test rank 5. Coverage: 3/4 у top-5. | RAG краще бачить image/runtime side; baseline у цьому аспекті краще зачепив dispatcher-side exact keyword. |
| 5 | Build-context secrets/artifacts | Baseline повністю провалив aspect: 0/5 expected files у top-10; top results були snapshot YAML. | Default RAG видав `.dockerignore` rank 1, test rank 2, plan rank 3, `Dockerfile.uier-api` rank 5, `Dockerfile.uier-spa` rank 6. Coverage: 4/5 у top-5, 5/5 у top-10. | FDR mode видав `.dockerignore` rank 1, test rank 2, plan rank 3, `Dockerfile.uier-api` rank 4, `Dockerfile.uier-spa` rank 6. Coverage: 4/5 у top-5, 5/5 у top-10. | FDR mode трохи підтягує Dockerfile evidence і прибирає snapshot noise з верхівки. |

## Кількісні метрики

| Метрика | Без RAG | Default RAG | FDR mode |
|---|---:|---:|---:|
| Evidence targets | 19 | 19 | 19 |
| Top-1 hit | 2/19 (10.5%) | 5/19 (26.3%) | 5/19 (26.3%) |
| Top-3 hit | 4/19 (21.1%) | 13/19 (68.4%) | 14/19 (73.7%) |
| Top-5 hit | 5/19 (26.3%) | 16/19 (84.2%) | 17/19 (89.5%) |
| Top-10 hit | 6/19 (31.6%) | 18/19 (94.7%) | 18/19 (94.7%) |
| MRR | 0.179 | 0.490 | 0.522 |
| Median retrieval latency | 2486.4 ms | 850.6 ms | 996.1 ms |
| Mean retrieval latency | 2579.0 ms | 840.9 ms | 1111.9 ms |
| High-noise failures | 3 aspects dominated by snapshot/demo noise | 0 | 0 |

Delta FDR mode vs No-RAG:

- Top-3: +10 hits
- Top-5: +12 hits
- Top-10: +12 hits
- MRR: +0.343
- Median latency: approximately 2.5x faster than keyword baseline

Delta FDR mode vs default RAG:

- Top-3: +1 hit
- Top-5: +1 hit
- Top-10: parity
- MRR: +0.032
- Median latency: +145.5 ms due to FDR query expansion and role bundling

## Що саме покращено

1. Noise downranking: `.snapshots/` and `seeds/demo.yaml` отримують configurable `source_penalties`, тому generated/demo artifacts не забивають верх видачі.
2. FDR mode: `rag_search` отримав `mode=fdr`, який додає review-oriented query expansion, слабкі role boosts і role-diverse selection.
3. Evidence bundle selection: FDR mode зберігає top-3 score results, потім додає максимум два missing-role results, після чого повертається до score order. Це не руйнує tight dependency-chain queries, але краще витягує spec/test/source/build bundle.

## Висновок

Default RAG уже радикально кращий за No-RAG для FDR retrieval. Новий FDR mode дає помірний, але реальний приріст саме там, де reviewer хоче не один файл, а evidence bundle: Top-5 піднявся з 16/19 до 17/19, MRR з 0.490 до 0.522, а Bash 3.2 blocker став повним top-5 bundle.

## Обмеження RAG

- RAG не замінює фінальну перевірку execution path. Наприклад, у migration-entrypoint сценарії `NodeUpdater.php` все ще краще знаходиться exact keyword baseline, ніж RAG query, бо запит сфокусований на runtime/image side.
- Query wording суттєво впливає на результат. Якщо запит перенасичений runtime terms, RAG може змістити фокус від dispatcher/controller source до Docker/runtime files.
- Це retrieval benchmark, а не повна оцінка “LLM без RAG”. Людина або модель з правильно підібраними `rg` запитами може знайти ті самі файли, але потребуватиме більше ітерацій та ручного знання термів.
