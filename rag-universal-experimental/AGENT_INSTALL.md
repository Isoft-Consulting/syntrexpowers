# Agent Install Playbook

This playbook is for agents that need to install or update the universal RAG toolkit inside an existing project.

The toolkit is project-local and provider-neutral. Codex, Claude, DeepSeek, or any MCP-capable model client can use the same copied files and the same stdio MCP command.

## Preconditions

- Python 3.8+ is available as `python3`. Sources use `from __future__ import annotations` (Python 3.7+), so PEP 604 / PEP 585 type hints stay strings at runtime; no `removeprefix`/`removesuffix` (3.9-only) or walrus-in-comprehension (3.8-only restriction) usages — the local test suite runs clean on 3.9, but the language-level floor is 3.8.
- You have filesystem access to both:
  - the source toolkit directory, usually `rag-universal-experimental/`;
  - the target project root.
- Do not commit generated `.rag-index/` artifacts.
- Do not copy local cache files, `__pycache__`, or stale index files into the target project.

## Install Or Update

From the repository that contains `rag-universal-experimental/`:

```bash
TARGET=/path/to/project

mkdir -p "$TARGET/.mcp/rag-server"
rsync -a --delete \
  --exclude '.rag-index/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  rag-universal-experimental/ "$TARGET/.mcp/rag-server/"
```

This is intentionally a full directory sync. It keeps the installed server deterministic and removes old files that no longer exist in the source toolkit.

## First Smoke Test

```bash
cd /path/to/project

python3 .mcp/rag-server/tools/rag.py status --root .
python3 .mcp/rag-server/tools/rag.py search --root . "project overview" --with-plan --auto-reindex --top-k 5
python3 .mcp/rag-server/tools/rag.py quality-check --root . --auto-reindex --summary-only
```

Expected result:

- `status` returns JSON.
- The first `search --auto-reindex` may rebuild the index.
- After rebuild, diagnostics should include `"index_stale_after_search": false`.
- Search should return project files or docs.
- `quality-check` returns comparative RAG vs keyword-baseline metrics and a `verdict.status`.

For large projects, the first rebuild can take minutes. If it is unexpectedly slow, run:

```bash
python3 .mcp/rag-server/tools/rag.py status --root .
```

Check `source_state.current.num_files`. If the count is inflated by generated/runtime files, add a project `rag.config.json` with narrower `exclude_dirs`, `exclude_globs`, or `include_globs`.

## Optional Project Config

Use a project-local config when default globs are too broad or too narrow:

```bash
cp .mcp/rag-server/rag.config.example.json rag.config.json
python3 .mcp/rag-server/tools/rag.py status --root . --config rag.config.json
python3 .mcp/rag-server/tools/rag.py search --root . "project overview" --config rag.config.json --with-plan --auto-reindex
```

List values in `rag.config.json` replace the built-in defaults. If you override `exclude_dirs`, keep the full safety set and add project-specific entries to it:

```json
{
  "schema_version": "rag.config.v1",
  "exclude_dirs": [
    ".git",
    ".mcp",
    ".claude",
    ".codex",
    ".agents",
    ".rag-index",
    "node_modules",
    "bower_components",
    "vendor",
    "dist",
    "build",
    "out",
    "target",
    "coverage",
    "evals",
    "storage",
    "payload",
    "sessions",
    "_tmp_storage",
    "_tmp_payload_storage",
    ".idea",
    ".vscode",
    ".next",
    ".nuxt",
    ".vite",
    ".turbo",
    ".yarn",
    ".pnpm-store",
    ".cache",
    "cache",
    "tmp",
    "temp",
    "logs",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache"
  ]
}
```

## MCP Configuration

For a project-local install under `.mcp/rag-server`, use this command shape in any stdio MCP client:

```json
{
  "mcpServers": {
    "rag": {
      "type": "stdio",
      "command": "python3",
      "args": [
        ".mcp/rag-server/tools/rag.py",
        "serve-mcp",
        "--root",
        "."
      ]
    }
  }
}
```

If the project uses a custom config, add:

```json
"--config",
"rag.config.json"
```

to the `args` list after `"."`.

Ready-made examples for a source-tree install are also available:

- `examples/mcp.generic.json`
- `examples/mcp.claude.json`
- `examples/mcp.deepseek.json`

The server does not branch on model/client name.

## Agent Usage Rules

Add this block to the target project's `AGENTS.md` or equivalent agent instructions:

```md
## RAG

Project-local RAG server is installed at `.mcp/rag-server`.

Before design, FDR, large implementation, or unfamiliar code exploration:
1. Call `rag_status`.
2. If stale, use `rag_search` with `auto_reindex=true`, or call `rag_reindex`.
3. Run `rag_quality_check` when installing/updating RAG or when search quality is suspect.
4. Prefer `with_plan=true` for review/design work.
5. Use task modes:
   - `fdr` for code review/FDR
   - `architecture` for module/spec design
   - `implementation` for coding tasks
   - `frontend` for UI work
   - `migration` for DB/schema work
   - `knowledge` for learned project review patterns

Do not commit `.rag-index/`.
Do not index secrets, `.env`, `.mcp.json`, vendor, node_modules, dist, storage, runtime payloads, or generated build output.
```

## Useful Commands

```bash
# Rebuild now
python3 .mcp/rag-server/tools/rag.py index --root .

# Check stale state
python3 .mcp/rag-server/tools/rag.py status --root .

# Search and rebuild only when stale
python3 .mcp/rag-server/tools/rag.py search --root . "query" --mode fdr --with-plan --auto-reindex

# Verify server health and comparative retrieval quality
python3 .mcp/rag-server/tools/rag.py quality-check --root . --auto-reindex --summary-only

# Watch and rebuild when files change
python3 .mcp/rag-server/tools/rag.py watch --root .

# Check whether generated knowledge pack inputs changed
python3 .mcp/rag-server/tools/rag.py knowledge-status --root . --summary Docs/knowledge/rag
```

## Safety Notes

- `.rag-index/` is generated and should stay untracked.
- `.mcp.json`, `.env`, private keys, certificates, and secret-named paths are excluded by default.
- If a project intentionally stores review-critical files under an excluded directory, add a narrow `force_include_globs` rule instead of indexing the whole directory.
- Prefer project-local install paths over global shared paths so each project can pin a known RAG toolkit version.
