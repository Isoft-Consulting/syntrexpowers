# Universal RAG Experimental

Reusable local RAG toolkit for project-aware agents. It builds a JSON index under `.rag-index` and exposes search through CLI commands or MCP stdio tools.

It is model-neutral. Codex, DeepSeek, Claude, or any other client can use the same server if it can launch a stdio MCP process. Non-MCP clients can still call the JSON CLI commands directly.

The v0 implementation is intentionally lightweight: Python standard library only, lexical vector scoring plus BM25, no model downloads. A future embedding backend can be added without changing the index safety rules or MCP tool contracts.

## Quick Start

```bash
cd rag-universal-experimental
python3 tools/rag.py index --root ..
python3 tools/rag.py status --root ..
python3 tools/rag.py search --root .. "strict mode stop guard"
python3 tools/rag.py symbol --root .. strict-hook
python3 tools/rag.py deps --root .. json --direction reverse
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
| `status` / `rag_status` | CLI, MCP | Inspect index counts, manifest, and stale config state. |
| `search` / `rag_search` | CLI, MCP | Ranked chunk retrieval with source/type filters. |
| `symbol` / `rag_symbol` | CLI, MCP | Exact symbol lookup. |
| `deps` / `rag_deps` | CLI, MCP | Forward or reverse dependency edge lookup. |

## Generated Artifacts

```text
.rag-index/
  manifest.json
  chunks.jsonl
  symbols.json
  deps.json
  files.json
```

Do not commit generated index artifacts. The repository `.gitignore` excludes `.rag-index/`.

## Tests

```bash
cd rag-universal-experimental
tests/run-tests.sh
```

## Quality Eval

`eval-quality` compares `rag_search` against a simple file-level keyword baseline on a gold-query JSON file:

```bash
python3 tools/rag.py index --root .. --config rag.config.example.json
python3 tools/rag.py eval-quality --root .. --config rag.config.example.json --cases evals/syntrexpowers-gold.json
```

Current `syntrexpowers` gold-set result after v2 lexical ranking:

| Mode | Top-1 | Top-3 | Top-5 | MRR |
|---|---:|---:|---:|---:|
| RAG v2 | 8/10 | 10/10 | 10/10 | 0.900 |
| Keyword baseline | 6/10 | 10/10 | 10/10 | 0.767 |

## Current Limits

- Search is lexical in v0, not embedding-semantic.
- Partial reindex is not implemented.
- Dependency extraction is shallow import/use extraction, not a call graph.
- JSON schemas document artifact shape but are not enforced by an external validator in v0 tests.
