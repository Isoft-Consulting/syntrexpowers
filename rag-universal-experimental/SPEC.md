# Universal RAG Experimental - Specification v0

Status: executable MVP
Target directory: `rag-universal-experimental/`
Goal: reusable project-local RAG indexing and MCP search toolkit for any repository and any MCP-capable model client.

This module is inspired by the Core project RAG server, but it is not a Core-specific copy. The contract is config-driven, safe by default, and designed to run without heavyweight dependencies in its first version.

## 7-Level Design

| Level | Definition |
|---|---|
| Supersystem | Local agent tooling: Codex CLI, Claude Code, DeepSeek Code, other MCP-capable clients, project repositories, and generated local indexes. |
| Mission | Provide fast project-local retrieval over code, docs, schemas, and specs so agents can inspect existing patterns before editing. |
| Concept | A universal RAG toolkit with CLI and MCP stdio surfaces. It is not a hosted search service, not a secret scanner, not a replacement for grep, and not a provider-specific hook runtime. |
| Values | Safe by default, portable, deterministic, inspectable, config-driven, and cheap to run locally. |
| Skills | Scan indexable files, chunk content, extract symbols, extract dependency edges, build index artifacts, search chunks, report status, serve MCP tools. |
| Behaviors | A user runs `rag.py index`; an agent calls `rag_search`; a reviewer calls `rag_status`; a developer queries exact symbols with `rag_symbol`; dependency context is available through `rag_deps`. |
| Environment | Python 3.10+, local filesystem, JSON artifacts under `.rag-index`, MCP stdio JSON-RPC, any client that can launch stdio MCP, no required network access, no required model download. |

## Module Boundary

Included in v0:

- Config-driven scanner with include, exclude, and secret-deny path rules.
- Deterministic chunking for Markdown, JSON/YAML-like configs, scripts, and source files.
- Standard-library lexical vector search and BM25 scoring with configurable noise penalties.
- Optional task modes: `fdr`, `architecture`, `implementation`, `frontend`, and `migration`.
- Canonical/superseded document status detection for Markdown specs, plans, and reports.
- Section-level read plans that tell clients which exact file sections to inspect before opening whole files.
- Markdown path-reference edges so plans/specs/reviews can be mapped to referenced code and tests.
- Knowledge-pack generation from review/eval cases with universal default owner rules and optional project-specific rules profiles.
- Symbol extraction for common docs and languages.
- Dependency edge extraction for Python, Ruby, JavaScript/TypeScript, shell, and PHP import forms.
- CLI commands: `index`, `status`, `coverage`, `search`, `symbol`, `deps`, `eval-quality`, `serve-mcp`.
- Quality command: `eval-quality` compares RAG retrieval against a keyword baseline on gold-query files.
- MCP tools: `rag_search`, `rag_reindex`, `rag_status`, `rag_coverage`, `rag_symbol`, `rag_deps`.
- JSON schemas for config and generated artifacts.
- Provider-neutral operation: Codex, DeepSeek, Claude, or another model client can use the same stdio server command if it supports MCP.

Excluded from v0:

- Remote embedding services.
- Mandatory `fastembed`, `faiss`, `numpy`, or model downloads.
- Full semantic embeddings parity with Core.
- Partial file reindex.
- Full call graph analysis.
- Storing credentials, `.env` files, private keys, or MCP configs in the index.
- Model-specific assumptions in the core index, search, or MCP tool behavior.

## Index Layout

Generated data is local and should not be committed:

```text
.rag-index/
  manifest.json
  chunks.jsonl
  symbols.json
  deps.json
  files.json
  search.sqlite
```

`manifest.json` is the integrity entry point. It records schema version, project root, config hash, index counts, tokenizer/chunker/search versions, a source-state fingerprint, and generated artifact names. `search.sqlite` stores precomputed postings/vector data for low-latency `rag_search`.

Review-critical files can be force-included with `force_include_globs` even when a parent directory is excluded. This is intended for narrow contracts such as `tests/Unit/*ContractTest.php` and `tests/Unit/*ScriptTest.php`, not for broad dependency trees.

## Safety Defaults

The default config excludes:

- `.git`, `.mcp`, `.claude`, `.codex`, `.agents`, `node_modules`, `vendor`, caches, build outputs.
- `.env`, `.env.*`, `.mcp.json`, private keys, certificates, and credential/secret-named files.
- Binary and large files.

Projects can loosen the rules explicitly in their own `rag.config.json`, but the checked-in example keeps the safe default posture.

## Consistency Checks

| Check | Result |
|---|---|
| Completeness | All 7 design levels are defined. |
| Mission alignment | The module supports the repository mission by making agent add-ons easier to inspect and reuse. |
| Concept clarity | Provider hooks and hosted search are outside the boundary. |
| Values to skills | Safety maps to deny rules, portability maps to stdlib MVP, inspectability maps to JSON artifacts. |
| Skills to behaviors | Every listed skill has a CLI command or MCP tool. |
| Environment fit | Python stdlib and local files are sufficient for v0 behaviors. |

## Acceptance Criteria

- `python3 tools/rag.py index --root <repo> --config <config>` builds all artifact files.
- `python3 tools/rag.py status --root <repo> --config <config>` reports index counts, stale config state, and stale source-file state.
- `python3 tools/rag.py coverage --root <repo> --config <config> <path>...` reports whether exact paths are indexed or why they are excluded.
- `python3 tools/rag.py search --root <repo> --config <config> "query"` returns ranked chunks.
- `python3 tools/rag.py search --root <repo> --config <config> "query" --mode fdr` returns review-oriented evidence bundles across plan/spec, implementation, test, and build/config roles when available.
- `python3 tools/rag.py search --root <repo> --config <config> "query" --mode architecture --with-plan` returns ranked chunks plus a section-level read plan and diagnostics.
- `python3 tools/rag.py search --root <repo> --config <config> "query" --mode knowledge --with-plan` prioritizes generated project-memory packs.
- Search results include `document_status`, `status_boost`, `section`, and `read_hint`.
- Superseded or historical documents are downranked and marked as deprioritized in read plans.
- `python3 tools/rag.py symbol --root <repo> --config <config> Name` returns exact symbol matches.
- `python3 tools/rag.py deps --root <repo> --config <config> target` returns dependency edges, including Markdown `path_reference` edges when docs cite repo paths.
- `python3 tools/rag.py eval-quality --root <repo> --config <config> --cases <cases.json>` reports Top-1, Top-3, Top-5, Top-10, and MRR.
- `python3 tools/rag.py knowledge-build --root <repo> --cases <cases.json> --output Docs/knowledge/rag --project <name>` writes normalized lessons, pattern registry, failure taxonomy, owner map, query templates, and summary.
- `knowledge-build --rules <rules.json>` may add project-specific owner mappings while keeping the generator itself project-neutral.
- `python3 tools/rag.py knowledge-profile --root <repo> --output rag.knowledge.json --project <name>` writes a starter rules profile from the repository layout.
- `python3 tools/rag.py serve-mcp --root <repo> --config <config>` speaks MCP stdio.
- Tests prove secret path exclusion, index artifact generation, search ranking, symbol lookup, dependency lookup, provider-neutral initialize handling, and MCP tool dispatch.
