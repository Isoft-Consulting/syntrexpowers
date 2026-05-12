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
    "auto_reindex_default": true,
    "require_explicit_root": true
  },
  "cli": {
    "auto_reindex_default": false
  }
}
```

`mcp.auto_reindex_default=true` means MCP `rag_search` refreshes stale indexes incrementally when possible. CLI commands stay explicit by default through `cli.auto_reindex_default=false`; use `search --auto-reindex`, `quality-check --auto-reindex`, or `index --incremental`. If a project enables CLI auto-reindex by config, disable it for one run with `--no-auto-reindex`.

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
        ".",
        "--require-explicit-root"
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

Every MCP tool accepts per-call `root` and `config` arguments. With `--require-explicit-root` or `mcp.require_explicit_root=true`, project-scoped tools reject missing or relative roots; diagnostic `rag_status` remains callable without `root` so agents can inspect `mcp_server.server_root`, `mcp_server.effective_root`, and `mcp_server.stale_namespace_risk`. In multi-project Codex/Claude sessions, the exposed `mcp__rag__` namespace can be backed by a long-lived MCP process that was started for a different repository. If `rag_status` reports the wrong `manifest.project_root` or `mcp_server.server_root`, pass the absolute current project path as `root` on every MCP call:

```json
{
  "root": "/path/to/current/project",
  "query": "project overview",
  "mode": "implementation",
  "with_plan": true
}
```

If the client has not refreshed the updated tool schema yet, use the CLI fallback with explicit `--root /path/to/current/project`.

## Agent Usage Rules

Add this block to the target project's `AGENTS.md` or equivalent agent instructions:

```md
## RAG

Project-local RAG server is installed at `.mcp/rag-server`.

Before design, FDR, large implementation, or unfamiliar code exploration:
1. Call `rag_status`.
2. Pass the absolute current project path as `root` on every project-scoped MCP call; if `rag_status` points at another repository or a root-required tool rejects the call, use the CLI fallback with explicit `--root`.
3. Use `rag_search` with `with_plan=true` and the task mode; MCP auto-reindexes stale indexes by default through `mcp.auto_reindex_default=true`.
4. Run `rag_quality_check` when installing/updating RAG or when search quality is suspect.
5. Prefer `with_plan=true` for review/design work.
6. Use task modes:
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

# Incremental refresh when the existing index is compatible
python3 .mcp/rag-server/tools/rag.py index --root . --incremental

# Check stale state
python3 .mcp/rag-server/tools/rag.py status --root .

# Search and rebuild only when stale
python3 .mcp/rag-server/tools/rag.py search --root . "query" --mode fdr --with-plan --auto-reindex

# Verify server health and comparative retrieval quality
python3 .mcp/rag-server/tools/rag.py quality-check --root . --auto-reindex --summary-only

# Watch and rebuild incrementally when possible
python3 .mcp/rag-server/tools/rag.py watch --root .

# Check whether generated knowledge pack inputs changed
python3 .mcp/rag-server/tools/rag.py knowledge-status --root . --summary Docs/knowledge/rag
```

## Safety Notes

- `.rag-index/` is generated and should stay untracked.
- `.mcp.json`, `.env`, private keys, certificates, and secret-named paths are excluded by default.
- If a project intentionally stores review-critical files under an excluded directory, add a narrow `force_include_globs` rule instead of indexing the whole directory.
- Prefer project-local install paths over global shared paths so each project can pin a known RAG toolkit version.
