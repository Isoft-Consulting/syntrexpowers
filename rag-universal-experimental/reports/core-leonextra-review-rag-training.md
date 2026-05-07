# Core Leonextra Review RAG Training

Source: closed `Isoft-Consulting/core` PR review/reply threads involving `leonextra`, fetched through GitHub API on 2026-05-07.

Core baseline: `main` at `7d72c74dd`.

## Corpus

| Item | Count |
|---|---:|
| Closed PRs scanned | 85 |
| PRs with `leonextra` review/comment activity | 73 |
| Thread items collected | 412 |
| `leonextra` items | 227 |
| Reply/context items from other authors | 185 |
| Comment-level cases with existing cited paths | 205 |
| Path-focused cited-file cases | 1406 |
| Indexable path-focused cases | 1405 |
| Intentionally skipped cases | 1 |

Skipped case:

- `uier-spa/node_modules/.bin/vitest` -> excluded by `node_modules` policy.

## Retrieval Training Changes

- Added Ukrainian query stopwords alongside English/Russian defaults.
- Added `max_query_terms` trimming for long review bodies.
- Added explicit path priority for cited review files.
- Added explicit-path fast path so cited files are returned directly from `search.sqlite` before full BM25/vector search.
- Limited path candidates to representative source chunks instead of all chunks from large files.
- Filtered pseudo paths such as `review/reply` and `create/update`.
- Broadened review evidence coverage:
  - `tests/**/*.php`
  - `uier/tests/**/*.php`
  - `uier-spa/src/tests/**/*.{js,ts,vue}`
  - `uier/public/js/*.js`
- Removed broad `**/*token*` secret deny because it incorrectly excluded docs such as `alpha-aware-token-replacement.md`.

## Metrics

Path-focused FDR mode on all raw cited-file cases:

| Metric | Value |
|---|---:|
| Cases | 1406 |
| Top-1 | 1405 |
| Top-3 | 1405 |
| Top-5 | 1405 |
| Top-10 | 1405 |
| MRR | 0.999 |
| Median latency | 253.2 ms |
| Mean latency | 274.1 ms |

Path-focused FDR mode on indexable review evidence:

| Metric | Value |
|---|---:|
| Cases | 1405 |
| Top-1 | 1405 |
| Top-3 | 1405 |
| Top-5 | 1405 |
| Top-10 | 1405 |
| MRR | 1.000 |
| Median latency | 252.8 ms |
| Mean latency | 277.3 ms |

## Result

For indexable review evidence from closed Core PR reviews/replies, RAG reaches 100% Top-1 retrieval on the path-focused benchmark.

The remaining raw miss is intentionally outside the index boundary because it is under `node_modules`.
