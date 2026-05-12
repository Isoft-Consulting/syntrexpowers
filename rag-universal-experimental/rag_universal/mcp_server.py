from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from .core import (
    build_index,
    configure_search_cache_storage,
    index_coverage,
    index_status,
    load_config,
    lookup_deps,
    lookup_symbol,
    resolve_root,
    search_index,
    search_index_with_plan,
)
from .eval_quality import quality_check
from .knowledge import build_project_knowledge, generate_project_profile, knowledge_pack_status

PROJECT_SCOPED_TOOLS = {
    "rag_search",
    "rag_reindex",
    "rag_coverage",
    "rag_symbol",
    "rag_deps",
    "rag_quality_check",
    "rag_knowledge_build",
    "rag_knowledge_profile",
    "rag_knowledge_status",
}


MCP_SCOPE_PROPERTIES: dict[str, dict[str, Any]] = {
    "root": {
        "type": ["string", "null"],
        "default": None,
        "description": "Project root override for this MCP call. Use an absolute path in multi-project agent sessions.",
    },
    "config": {
        "type": ["string", "null"],
        "default": None,
        "description": "Config path override for this MCP call. Relative paths resolve against root first.",
    },
}


def mcp_properties(properties: dict[str, Any], require_explicit_root: bool = False) -> dict[str, Any]:
    scope = dict(MCP_SCOPE_PROPERTIES)
    if require_explicit_root:
        scope["root"] = {
            **scope["root"],
            "description": "Absolute project root for this MCP call. Required in hardened multi-project sessions.",
        }
    return {**scope, **properties}


def schema_for(properties: dict[str, Any], required: list[str] | None = None, require_root: bool = False) -> dict[str, Any]:
    schema = {
        "type": "object",
        "properties": mcp_properties(properties, require_explicit_root=require_root),
    }
    required_fields = list(required or [])
    if require_root and "root" not in required_fields:
        required_fields.insert(0, "root")
    if required_fields:
        schema["required"] = required_fields
    return schema


def tool_definitions(require_explicit_root: bool = False) -> list[dict[str, Any]]:
    return [
        {
            "name": "rag_search",
            "description": "Search the local project RAG index with lexical vector + BM25 ranking, task modes, and optional read plan.",
            "inputSchema": schema_for(
                {
                    "query": {"type": "string"},
                    "top_k": {"type": "integer", "default": 5, "minimum": 1, "maximum": 50},
                    "filter_source": {"type": ["string", "null"], "default": None},
                    "filter_type": {"type": ["string", "null"], "default": None},
                    "mode": {
                        "type": "string",
                        "enum": ["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"],
                        "default": "default",
                    },
                    "with_plan": {"type": "boolean", "default": False},
                    "auto_reindex": {
                        "type": "boolean",
                        "description": "When omitted, uses mcp.auto_reindex_default from rag.config.json; project default is true.",
                    },
                },
                ["query"],
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_reindex",
            "description": "Rebuild the local project RAG index.",
            "inputSchema": schema_for({}, require_root=require_explicit_root),
        },
        {
            "name": "rag_status",
            "description": "Return local RAG index status, manifest counts, and MCP server root diagnostics.",
            "inputSchema": schema_for({}),
        },
        {
            "name": "rag_coverage",
            "description": "Report whether specific project paths are present in the local RAG index.",
            "inputSchema": schema_for(
                {
                    "paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "minItems": 1,
                    }
                },
                ["paths"],
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_symbol",
            "description": "Exact symbol lookup by name and optional kind.",
            "inputSchema": schema_for(
                {
                    "name": {"type": "string"},
                    "kind": {"type": ["string", "null"], "default": None},
                    "limit": {"type": "integer", "default": 20, "minimum": 1, "maximum": 50},
                },
                ["name"],
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_deps",
            "description": "Look up forward or reverse import dependency edges.",
            "inputSchema": schema_for(
                {
                    "target": {"type": "string"},
                    "direction": {"type": "string", "enum": ["reverse", "forward"], "default": "reverse"},
                    "limit": {"type": "integer", "default": 20, "minimum": 1, "maximum": 50},
                },
                ["target"],
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_knowledge_build",
            "description": "Build a normalized lessons/patterns/owner-map knowledge pack from review or eval cases.",
            "inputSchema": schema_for(
                {
                    "cases": {"type": "string"},
                    "output": {"type": "string", "default": "Docs/knowledge/rag"},
                    "project": {"type": "string", "default": "project"},
                    "rules": {"type": ["string", "null"], "default": None},
                },
                ["cases"],
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_quality_check",
            "description": "Run RAG health and comparative quality metrics against a keyword baseline.",
            "inputSchema": schema_for(
                {
                    "cases": {"type": ["string", "null"], "default": None},
                    "case_limit": {"type": "integer", "default": 25, "minimum": 1, "maximum": 200},
                    "top_k": {"type": "integer", "default": 10, "minimum": 1, "maximum": 50},
                    "mode": {
                        "type": "string",
                        "enum": ["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"],
                        "default": "default",
                    },
                    "auto_reindex": {"type": "boolean", "default": False},
                    "include_cases": {"type": "boolean", "default": True},
                    "min_cases": {"type": "integer", "default": 5, "minimum": 1},
                    "min_top3_ratio": {"type": "number", "default": 0.6},
                    "min_mrr": {"type": "number", "default": 0.4},
                },
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_knowledge_profile",
            "description": "Generate a starter project-specific knowledge rules profile from repository layout.",
            "inputSchema": schema_for(
                {
                    "output": {"type": "string", "default": "rag.knowledge.json"},
                    "project": {"type": "string", "default": "project"},
                },
                require_root=require_explicit_root,
            ),
        },
        {
            "name": "rag_knowledge_status",
            "description": "Report whether a generated knowledge pack is stale against its cases/rules inputs.",
            "inputSchema": schema_for(
                {
                    "summary": {"type": "string", "default": "Docs/knowledge/rag/summary.json"},
                },
                require_root=require_explicit_root,
            ),
        },
    ]


def success(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def text_content(value: Any) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)}]}


def mcp_auto_reindex_default(config_data: dict[str, Any]) -> bool:
    mcp_config = config_data.get("mcp")
    if isinstance(mcp_config, dict):
        value = mcp_config.get("auto_reindex_default")
        if isinstance(value, bool):
            return value
    return True


def mcp_require_explicit_root_default(config_data: dict[str, Any]) -> bool:
    mcp_config = config_data.get("mcp")
    if isinstance(mcp_config, dict):
        value = mcp_config.get("require_explicit_root")
        if isinstance(value, bool):
            return value
    return False


def env_bool(name: str) -> bool | None:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return None
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be boolean-like, got {raw!r}")


def resolve_mcp_require_explicit_root(root: str | None, config: str | None, override: bool | None = None) -> bool:
    if override is not None:
        return bool(override)
    env_value = env_bool("RAG_MCP_REQUIRE_EXPLICIT_ROOT")
    if env_value is not None:
        return env_value
    return mcp_require_explicit_root_default(load_config(resolve_root(root), config))


def resolve_mcp_auto_reindex(arguments: dict[str, Any], root: str | None, config: str | None) -> bool:
    if "auto_reindex" in arguments and arguments.get("auto_reindex") is not None:
        return bool(arguments["auto_reindex"])
    return mcp_auto_reindex_default(load_config(resolve_root(root), config))


def explicit_root_argument(arguments: dict[str, Any]) -> str | None:
    requested_root = arguments.get("root")
    if requested_root in (None, ""):
        return None
    text = str(requested_root).strip()
    return text or None


def root_argument_is_absolute(root_value: str) -> bool:
    return Path(os.path.expanduser(root_value)).is_absolute()


def resolve_mcp_scope(arguments: dict[str, Any], root: str | None, config: str | None) -> tuple[str | None, str | None]:
    requested_root = explicit_root_argument(arguments)
    requested_config = arguments.get("config")
    effective_root = requested_root if requested_root is not None else root
    effective_config = str(requested_config) if requested_config not in (None, "") else config
    return effective_root, effective_config


def enforce_explicit_root(name: str, arguments: dict[str, Any], require_explicit_root: bool) -> None:
    if not require_explicit_root:
        return
    root_value = explicit_root_argument(arguments)
    if root_value is not None and not root_argument_is_absolute(root_value):
        raise ValueError("rag MCP explicit root must be an absolute path; relative roots bind to the MCP server process cwd")
    if name in PROJECT_SCOPED_TOOLS and root_value is None:
        raise ValueError(
            "rag MCP explicit root required: pass an absolute per-call root, "
            'for example {"root": "/path/to/current/project", ...}; '
            "call rag_status without root to inspect the server-bound root"
        )


def status_with_mcp_scope(
    status: dict[str, Any],
    arguments: dict[str, Any],
    root: str | None,
    config: str | None,
    tool_root: str | None,
    require_explicit_root: bool,
) -> dict[str, Any]:
    root_value = explicit_root_argument(arguments)
    status["mcp_server"] = {
        "server_root": str(resolve_root(root)),
        "server_config": config,
        "effective_root": str(resolve_root(tool_root)),
        "effective_config": config if arguments.get("config") in (None, "") else str(arguments.get("config")),
        "explicit_root": root_value is not None,
        "require_explicit_root": require_explicit_root,
        "stale_namespace_risk": require_explicit_root and root_value is None,
        "guidance": "Pass an absolute root on every project-scoped MCP call in multi-project sessions.",
    }
    return status


def call_tool(name: str, arguments: dict[str, Any], root: str | None, config: str | None, require_explicit_root: bool = False) -> Any:
    enforce_explicit_root(name, arguments, require_explicit_root)
    tool_root, tool_config = resolve_mcp_scope(arguments, root, config)
    if name == "rag_search":
        search_fn = search_index_with_plan if bool(arguments.get("with_plan", False)) else search_index
        auto_reindex = resolve_mcp_auto_reindex(arguments, tool_root, tool_config)
        return text_content(
            search_fn(
                tool_root,
                tool_config,
                str(arguments.get("query", "")),
                int(arguments.get("top_k", 5)),
                arguments.get("filter_source"),
                arguments.get("filter_type"),
                str(arguments.get("mode", "default")),
                auto_reindex,
            )
        )
    if name == "rag_reindex":
        return text_content(build_index(tool_root, tool_config))
    if name == "rag_status":
        return text_content(status_with_mcp_scope(index_status(tool_root, tool_config), arguments, root, config, tool_root, require_explicit_root))
    if name == "rag_coverage":
        raw_paths = arguments.get("paths", [])
        paths = [str(item) for item in raw_paths] if isinstance(raw_paths, list) else [str(raw_paths)]
        return text_content(index_coverage(tool_root, tool_config, paths))
    if name == "rag_symbol":
        return text_content(
            lookup_symbol(
                tool_root,
                tool_config,
                str(arguments.get("name", "")),
                arguments.get("kind"),
                int(arguments.get("limit", 20)),
            )
        )
    if name == "rag_deps":
        return text_content(
            lookup_deps(
                tool_root,
                tool_config,
                str(arguments.get("target", "")),
                str(arguments.get("direction", "reverse")),
                int(arguments.get("limit", 20)),
            )
        )
    if name == "rag_knowledge_build":
        return text_content(
            build_project_knowledge(
                tool_root,
                str(arguments.get("cases", "")),
                str(arguments.get("output", "Docs/knowledge/rag")),
                str(arguments.get("project", "project")),
                arguments.get("rules"),
            )
        )
    if name == "rag_quality_check":
        return text_content(
            quality_check(
                tool_root,
                tool_config,
                arguments.get("cases"),
                int(arguments.get("case_limit", 25)),
                int(arguments.get("top_k", 10)),
                str(arguments.get("mode", "default")),
                bool(arguments.get("auto_reindex", False)),
                bool(arguments.get("include_cases", True)),
                int(arguments.get("min_cases", 5)),
                float(arguments.get("min_top3_ratio", 0.6)),
                float(arguments.get("min_mrr", 0.4)),
            )
        )
    if name == "rag_knowledge_profile":
        return text_content(
            generate_project_profile(
                tool_root,
                str(arguments.get("output", "rag.knowledge.json")),
                str(arguments.get("project", "project")),
            )
        )
    if name == "rag_knowledge_status":
        return text_content(knowledge_pack_status(tool_root, str(arguments.get("summary", "Docs/knowledge/rag/summary.json"))))
    raise ValueError(f"unknown tool: {name}")


def handle_message(message: dict[str, Any], root: str | None = None, config: str | None = None, require_explicit_root: bool | None = None) -> dict[str, Any] | None:
    method = message.get("method")
    message_id = message.get("id")
    require_root = resolve_mcp_require_explicit_root(root, config, require_explicit_root)

    if method == "notifications/initialized":
        return None
    if method == "initialize":
        return success(
            message_id,
            {
                "protocolVersion": message.get("params", {}).get("protocolVersion", "2024-11-05"),
                "serverInfo": {"name": "rag-universal", "version": "0.1.0"},
                "capabilities": {"tools": {}},
            },
        )
    if method == "tools/list":
        return success(message_id, {"tools": tool_definitions(require_explicit_root=require_root)})
    if method == "tools/call":
        params = message.get("params", {})
        try:
            result = call_tool(str(params.get("name", "")), params.get("arguments", {}) or {}, root, config, require_explicit_root=require_root)
            return success(message_id, result)
        except Exception as exc:
            return error(message_id, -32000, str(exc))
    if message_id is None:
        return None
    return error(message_id, -32601, f"method not found: {method}")


def run_stdio(root: str | None = None, config: str | None = None, cache_storage: str = "disk", require_explicit_root: bool | None = None) -> int:
    configure_search_cache_storage(cache_storage)
    require_root = resolve_mcp_require_explicit_root(root, config, require_explicit_root)
    print(f"rag-universal MCP server started (cache_storage={cache_storage}, require_explicit_root={require_root})", file=sys.stderr)
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
            response = handle_message(message, root, config, require_explicit_root=require_root)
        except Exception as exc:
            response = error(None, -32700, str(exc))
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0
