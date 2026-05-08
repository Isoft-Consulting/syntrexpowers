# Universal RAG Experimental

Reusable local RAG toolkit for project-aware agents. It builds a JSON index under `.rag-index` and exposes search through CLI commands or MCP stdio tools.

It is model-neutral. Codex, DeepSeek, Claude, or any other client can use the same server if it can launch a stdio MCP process. Non-MCP clients can still call the JSON CLI commands directly.

The v0 implementation is intentionally lightweight: Python standard library only, lexical vector scoring plus BM25, no model downloads. A future embedding backend can be added without changing the index safety rules or MCP tool contracts.

For agent-driven installation into another repository, use [`AGENT_INSTALL.md`](AGENT_INSTALL.md).

## Quick Start

```bash
cd rag-universal-experimental
python3 tools/rag.py index --root ..
python3 tools/rag.py status --root ..
python3 tools/rag.py search --root .. "strict mode stop guard"
python3 tools/rag.py search --root .. "Visual Studio owner boundaries" --mode architecture --with-plan --auto-reindex
python3 tools/rag.py watch --root ..
python3 tools/rag.py symbol --root .. strict-hook
python3 tools/rag.py deps --root .. json --direction reverse
python3 tools/rag.py quality-check --root .. --auto-reindex --summary-only
python3 tools/rag.py eval-quality --root .. --cases evals/syntrexpowers-gold.json
```

Use an explicit config:

```bash
python3 tools/rag.py index --root .. --config rag.config.example.json
```

Run as an MCP server:

```bash
python3 tools/rag.py serve-mcp --root .. --config rag.config.example.json
```

Example MCP config entry for a generic stdio MCP client:

```json
{
  "mcpServers": {
    "rag": {
      "type": "stdio",
      "command": "python3",
      "args": [
        "rag-universal-experimental/tools/rag.py",
        "serve-mcp",
        "--root",
        ".",
        "--config",
        "rag-universal-experimental/rag.config.example.json"
      ]
    }
  }
}
```

DeepSeek Code and Claude Code use the same command shape when configured through a project `.mcp.json` or equivalent MCP server settings:

```json
{
  "mcpServers": {
    "rag": {
      "type": "stdio",
      "command": "python3",
      "args": [
        "rag-universal-experimental/tools/rag.py",
        "serve-mcp",
        "--root",
        ".",
        "--config",
        "rag-universal-experimental/rag.config.example.json"
      ]
    }
  }
}
```

Ready-to-copy examples are available in `examples/mcp.generic.json`, `examples/mcp.deepseek.json`, and `examples/mcp.claude.json`.

The server does not branch on `clientInfo.name`; it exposes the same tool contracts to every MCP client.

## Tools

| Tool | Surface | Purpose |
|---|---|---|
| `index` / `rag_reindex` | CLI, MCP | Build the local `.rag-index`. |
| `status` / `rag_status` | CLI, MCP | Inspect index counts, manifest, stale config state, and source-change state. |
| `coverage` / `rag_coverage` | CLI, MCP | Explain whether specific paths are indexed or excluded. |
| `search` / `rag_search` | CLI, MCP | Ranked chunk retrieval with source/type filters, task modes, optional read-plan output, and optional stale-index rebuild. |
| `watch` | CLI | Poll the project and rebuild when indexed files are added, changed, or deleted. |
| `symbol` / `rag_symbol` | CLI, MCP | Exact symbol lookup. |
| `deps` / `rag_deps` | CLI, MCP | Forward or reverse dependency edge lookup. |
| `quality-check` / `rag_quality_check` | CLI, MCP | Health check plus comparative RAG vs keyword-baseline metrics. |
| `knowledge-build` / `rag_knowledge_build` | CLI, MCP | Build normalized lessons, pattern registry, owner map, failure taxonomy, and query templates from review/eval cases. |
| `knowledge-status` / `rag_knowledge_status` | CLI, MCP | Check whether a knowledge pack is stale against its source cases/rules. |

## Generated Artifacts

```text
.rag-index/
  manifest.json
  chunks.jsonl
  symbols.json
  deps.json
  files.json
  search.sqlite
```

`search.sqlite` stores precomputed postings/vector data used by `rag_search`, and `manifest.json` stores a source-state fingerprint so `rag_status` can report when indexed files changed. Do not commit generated index artifacts. The repository `.gitignore` excludes `.rag-index/`.

For changing projects, use one of two refresh modes:

```bash
python3 tools/rag.py search --root /path/to/project "query" --auto-reindex
python3 tools/rag.py search --root /path/to/project "query" --with-plan --auto-reindex
python3 tools/rag.py watch --root /path/to/project
```

`--auto-reindex` checks `rag_status` before a search and performs a full rebuild only when the manifest is missing or stale. `--with-plan` diagnostics report whether the index was stale before search, whether it was rebuilt, and whether it is still stale after search. `watch` is a simple polling loop for long-lived local sessions.

`force_include_globs` can include narrow review-critical files from otherwise excluded directories, for example `tests/Unit/*ContractTest.php` while keeping the rest of `tests/` out of the index. Runtime/generated directories such as `node_modules`, `vendor`, `dist`, `storage`, `_tmp_storage`, `payload`, and `.git` are excluded by default. `Dockerfile`, `Dockerfile.*`, and `.dockerignore` are included by default because build contracts are common FDR evidence.

## Quality Check

`quality-check` verifies that the server can read the index, retrieve expected sources, compare RAG retrieval against a keyword baseline, and produce a pass/fail verdict:

```bash
python3 tools/rag.py quality-check --root /path/to/project --auto-reindex --summary-only
```

Without `--cases`, the command generates deterministic smoke cases from the current index and reports Top-1, Top-3, Top-5, Top-10, MRR, baseline metrics, deltas, index health, and verdict thresholds. For stronger project-specific validation, pass a gold case file:

```bash
python3 tools/rag.py quality-check \
  --root /path/to/project \
  --cases evals/project-gold.json \
  --mode fdr \
  --auto-reindex
```

Use `eval-quality` when you only need raw retrieval metrics for a known cases file. Use `quality-check` as the operational RAG gate before relying on the server in a project.

Search applies configurable `source_penalties` to downrank high-noise generated artifacts such as `.snapshots/` and demo seeds. It also detects document trust status from Markdown content: `Canonical` / implementation-ready docs are boosted, while `SUPERSEDED` and `DO NOT IMPLEMENT` documents are strongly downranked and shown as deprioritized read-plan items.

Task modes tune retrieval for common agent workflows:

| Mode | Use |
|---|---|
| `default` | General project search. |
| `fdr` | Review/FDR evidence bundles with plan/spec, implementation, test, and build/config roles. |
| `architecture` | Canonical specs, owner boundaries, module concepts, forbidden drift. |
| `implementation` | Controllers, services, routes, stores, tests, and local contracts. |
| `frontend` | SPA views, components, stores, API clients, routes, i18n, and frontend tests. |
| `migration` | Schema changes, migrations, repositories, rollback/backfill contracts. |
| `knowledge` | Project memory first: lessons, pattern registry, failure taxonomy, owner map, query templates. |

`--with-plan` returns `{ results, read_plan, diagnostics }`. The read plan gives section-level `read_hint` values and a token-budget guard so clients can inspect specific sections first instead of opening whole files. Diagnostics also surface explicit paths from the query and suggested next steps when retrieval returns no results.

Markdown documents that cite repository paths now create `path_reference` dependency edges. This gives agents a lightweight cross-artifact map from plans/specs/reviews to the code and tests they mention, available through `rag_deps`.

## Knowledge Packs

`knowledge-build` turns review/eval cases into a project-memory pack:

```bash
python3 tools/rag.py knowledge-build \
  --root /path/to/project \
  --cases /path/to/review-cases.json \
  --output Docs/knowledge/rag \
  --project my-project
```

Generated artifacts:

```text
Docs/knowledge/rag/
  lessons.jsonl
  patterns.json
  owner-map.json
  patterns.md
  failure-taxonomy.md
  owner-map.md
  query-templates.md
  summary.json
```

The generator is universal by default. It uses generic path ownership rules such as `src/`, `app/`, `routes/`, `tests/`, `docs/`, `plugins/`, `migrations/`, `Dockerfile`, and `.dockerignore`. Projects can pass an optional rules profile to improve owner names without changing the universal engine:

Generate a starter profile from a project layout:

```bash
python3 tools/rag.py knowledge-profile \
  --root /path/to/project \
  --output rag.knowledge.json \
  --project my-project
```

```bash
python3 tools/rag.py knowledge-build \
  --root /path/to/project \
  --cases /path/to/review-cases.json \
  --output Docs/knowledge/rag \
  --project core \
  --rules rag-universal-experimental/examples/knowledge.core.json
```

```bash
python3 tools/rag.py knowledge-status \
  --root /path/to/project \
  --summary Docs/knowledge/rag
```

The checked-in `knowledge/core-review/` pack is a Core-specific example built from the `leonextra` review gold set using `examples/knowledge.core.json`. It demonstrates the format; other projects should generate their own pack from their own review/FDR cases.

After indexing a project with a knowledge pack, use `mode=knowledge` before implementation/FDR work:

```bash
python3 tools/rag.py search --root /path/to/project "route contract owner boundary" --mode knowledge --with-plan
```

## Tests

```bash
cd rag-universal-experimental
tests/run-tests.sh
```

## Quality Eval

`eval-quality` compares `rag_search` against a simple file-level keyword baseline on a gold-query JSON file:

```bash
python3 tools/rag.py index --root .. --config rag.config.example.json
python3 tools/rag.py eval-quality --root .. --config rag.config.example.json --cases evals/syntrexpowers-gold.json --mode fdr
```

For large path-focused gold sets, skip the expensive keyword baseline and emit only aggregate metrics:

```bash
python3 tools/rag.py eval-quality --root /path/to/project --config /path/to/rag.config.json --cases evals/core-leonextra-path-gold.json --mode fdr --skip-baseline --summary-only
```

Current `syntrexpowers` gold-set result after v6 lexical ranking:

| Mode | Top-1 | Top-3 | Top-5 | Top-10 | MRR |
|---|---:|---:|---:|---:|---:|
| RAG v6 | 8/10 | 10/10 | 10/10 | 10/10 | 0.900 |
| Keyword baseline | 6/10 | 10/10 | 10/10 | 10/10 | 0.767 |

## Current Limits

- Search is lexical in v0, not embedding-semantic.
- Partial reindex is not implemented; `--auto-reindex`, `watch`, and `rag_reindex` all perform full rebuilds when the source-state fingerprint changes.
- Dependency extraction is shallow import/use extraction, not a call graph.
- JSON schemas document artifact shape but are not enforced by an external validator in v0 tests.
