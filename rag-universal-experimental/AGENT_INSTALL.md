# Agent Install Playbook

This playbook is for agents that need to install or update the universal RAG toolkit inside an existing project.

The toolkit is project-local and provider-neutral. Codex, Claude, DeepSeek, or any MCP-capable model client can use the same copied files and the same stdio MCP command.

## Preconditions

- Python 3.10+ is available as `python3`.
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

Check `source_state.current.num_files`. If the count is inflated by generated/runtime files, add a project `.mcp/rag-server/rag.config.json` with narrower `exclude_dirs`, `exclude_globs`, or `include_globs`.

## Optional Project Config

Use a project-local config when default globs are too broad or too narrow:

```bash
cp .mcp/rag-server/rag.config.example.json .mcp/rag-server/rag.config.json
python3 .mcp/rag-server/tools/rag.py status --root .
python3 .mcp/rag-server/tools/rag.py search --root . "project overview" --with-plan --auto-reindex
```

Keep generated/runtime directories excluded. Common examples:

```json
{
  "schema_version": "rag.config.v1",
  "exclude_dirs": [
    ".git",
    ".mcp",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "storage",
    "payload",
    "sessions",
    "_tmp_storage",
    "_tmp_payload_storage"
  ],
  "mcp": {
    "auto_reindex_default": true
  },
  "cli": {
    "auto_reindex_default": false
  }
}
```

`mcp.auto_reindex_default=true` means MCP `rag_search` refreshes stale indexes incrementally when needed. Source-only staleness is scoped: pass MCP `focus_paths` or CLI `--focus-path` for the current task files/directories, and source changes outside that scope will not trigger auto-reindex. Broad searches without focus observe `freshness.auto_reindex_source_grace_seconds` after a recent auto-reindex to avoid multi-agent rebuild storms. CLI commands stay explicit by default through `cli.auto_reindex_default=false`; use `search --auto-reindex`, `quality-check --auto-reindex`, or `index`. Plain `index` prefers incremental planning when an existing compatible manifest is present; use `index --full-rebuild` only for intentional full rebuilds. If a project enables CLI auto-reindex by config, disable it for one run with `--no-auto-reindex`.

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

If the project uses a custom config outside the default `.mcp/rag-server/rag.config.json` location, add:

```json
"--config",
".mcp/rag-server/rag.config.json"
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
2. Use `rag_search` with `with_plan=true` and the task mode; MCP auto-reindexes stale indexes by default through `mcp.auto_reindex_default=true`.
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
# Operational refresh workflow for Core
./rag-refresh.sh         # status + incremental rebuild when stale
./rag-refresh.sh --quality  # + quality-check summary
./rag-refresh.sh --full     # rebuild full index

# Refresh now, incremental when compatible
python3 .mcp/rag-server/tools/rag.py index --root . --config .mcp/rag-server/rag.config.json

# Force a full rebuild only when incremental planning is not desired
python3 .mcp/rag-server/tools/rag.py index --root . --config .mcp/rag-server/rag.config.json --full-rebuild

# Check stale state
python3 .mcp/rag-server/tools/rag.py status --root . --config .mcp/rag-server/rag.config.json

# Quick daily workflow (incremental when stale + smoke verification, no forced full rebuild):
./rag-refresh.sh --daily
./rag-refresh.sh --daily --quality  # include quick quality check

# Backward-compatible quick workflow (manual checks only):
./rag-refresh.sh  # status + optional incremental rebuild + smoke search

# Search and rebuild only when stale in the current scope
python3 .mcp/rag-server/tools/rag.py search --root . --config .mcp/rag-server/rag.config.json "query" --mode fdr --with-plan --auto-reindex --focus-path src/current-scope

# Verify server health and comparative retrieval quality
python3 .mcp/rag-server/tools/rag.py quality-check --root . --config .mcp/rag-server/rag.config.json --auto-reindex --summary-only

# Watch and rebuild incrementally when possible
python3 .mcp/rag-server/tools/rag.py watch --root . --config .mcp/rag-server/rag.config.json

# Check whether generated knowledge pack inputs changed
python3 .mcp/rag-server/tools/rag.py knowledge-status --root . --config .mcp/rag-server/rag.config.json --summary Docs/knowledge/rag
```

## Safety Notes

- `.rag-index/` is generated and should stay untracked.
- `.mcp.json`, `.env`, private keys, certificates, and secret-named paths are excluded by default.
- If a project intentionally stores review-critical files under an excluded directory, add a narrow `force_include_globs` rule instead of indexing the whole directory.
- Prefer project-local install paths over global shared paths so each project can pin a known RAG toolkit version.
