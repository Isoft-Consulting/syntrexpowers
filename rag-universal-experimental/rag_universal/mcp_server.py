from __future__ import annotations

import json
import sys
from typing import Any

from .core import build_index, index_coverage, index_status, lookup_deps, lookup_symbol, search_index, search_index_with_plan
from .eval_quality import quality_check
from .knowledge import build_project_knowledge, generate_project_profile, knowledge_pack_status


def tool_definitions() -> list[dict[str, Any]]:
    return [
        {
            "name": "rag_search",
            "description": "Search the local project RAG index with lexical vector + BM25 ranking, task modes, and optional read plan.",
            "inputSchema": {
                "type": "object",
                "properties": {
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
                    "auto_reindex": {"type": "boolean", "default": False},
                },
                "required": ["query"],
            },
        },
        {
            "name": "rag_reindex",
            "description": "Rebuild the local project RAG index.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "rag_status",
            "description": "Return local RAG index status and manifest counts.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "rag_coverage",
            "description": "Report whether specific project paths are present in the local RAG index.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "minItems": 1,
                    }
                },
                "required": ["paths"],
            },
        },
        {
            "name": "rag_symbol",
            "description": "Exact symbol lookup by name and optional kind.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "kind": {"type": ["string", "null"], "default": None},
                    "limit": {"type": "integer", "default": 20, "minimum": 1, "maximum": 50},
                },
                "required": ["name"],
            },
        },
        {
            "name": "rag_deps",
            "description": "Look up forward or reverse import dependency edges.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "target": {"type": "string"},
                    "direction": {"type": "string", "enum": ["reverse", "forward"], "default": "reverse"},
                    "limit": {"type": "integer", "default": 20, "minimum": 1, "maximum": 50},
                },
                "required": ["target"],
            },
        },
        {
            "name": "rag_knowledge_build",
            "description": "Build a normalized lessons/patterns/owner-map knowledge pack from review or eval cases.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cases": {"type": "string"},
                    "output": {"type": "string", "default": "Docs/knowledge/rag"},
                    "project": {"type": "string", "default": "project"},
                    "rules": {"type": ["string", "null"], "default": None},
                },
                "required": ["cases"],
            },
        },
        {
            "name": "rag_quality_check",
            "description": "Run RAG health and comparative quality metrics against a keyword baseline.",
            "inputSchema": {
                "type": "object",
                "properties": {
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
            },
        },
        {
            "name": "rag_knowledge_profile",
            "description": "Generate a starter project-specific knowledge rules profile from repository layout.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "output": {"type": "string", "default": "rag.knowledge.json"},
                    "project": {"type": "string", "default": "project"},
                },
            },
        },
        {
            "name": "rag_knowledge_status",
            "description": "Report whether a generated knowledge pack is stale against its cases/rules inputs.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "summary": {"type": "string", "default": "Docs/knowledge/rag/summary.json"},
                },
            },
        },
    ]


def success(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def text_content(value: Any) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)}]}


def call_tool(name: str, arguments: dict[str, Any], root: str | None, config: str | None) -> Any:
    if name == "rag_search":
        search_fn = search_index_with_plan if bool(arguments.get("with_plan", False)) else search_index
        return text_content(
            search_fn(
                root,
                config,
                str(arguments.get("query", "")),
                int(arguments.get("top_k", 5)),
                arguments.get("filter_source"),
                arguments.get("filter_type"),
                str(arguments.get("mode", "default")),
                bool(arguments.get("auto_reindex", False)),
            )
        )
    if name == "rag_reindex":
        return text_content(build_index(root, config))
    if name == "rag_status":
        return text_content(index_status(root, config))
    if name == "rag_coverage":
        raw_paths = arguments.get("paths", [])
        paths = [str(item) for item in raw_paths] if isinstance(raw_paths, list) else [str(raw_paths)]
        return text_content(index_coverage(root, config, paths))
    if name == "rag_symbol":
        return text_content(
            lookup_symbol(
                root,
                config,
                str(arguments.get("name", "")),
                arguments.get("kind"),
                int(arguments.get("limit", 20)),
            )
        )
    if name == "rag_deps":
        return text_content(
            lookup_deps(
                root,
                config,
                str(arguments.get("target", "")),
                str(arguments.get("direction", "reverse")),
                int(arguments.get("limit", 20)),
            )
        )
    if name == "rag_knowledge_build":
        return text_content(
            build_project_knowledge(
                root,
                str(arguments.get("cases", "")),
                str(arguments.get("output", "Docs/knowledge/rag")),
                str(arguments.get("project", "project")),
                arguments.get("rules"),
            )
        )
    if name == "rag_quality_check":
        return text_content(
            quality_check(
                root,
                config,
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
                root,
                str(arguments.get("output", "rag.knowledge.json")),
                str(arguments.get("project", "project")),
            )
        )
    if name == "rag_knowledge_status":
        return text_content(knowledge_pack_status(root, str(arguments.get("summary", "Docs/knowledge/rag/summary.json"))))
    raise ValueError(f"unknown tool: {name}")


def handle_message(message: dict[str, Any], root: str | None = None, config: str | None = None) -> dict[str, Any] | None:
    method = message.get("method")
    message_id = message.get("id")

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
        return success(message_id, {"tools": tool_definitions()})
    if method == "tools/call":
        params = message.get("params", {})
        try:
            result = call_tool(str(params.get("name", "")), params.get("arguments", {}) or {}, root, config)
            return success(message_id, result)
        except Exception as exc:
            return error(message_id, -32000, str(exc))
    if message_id is None:
        return None
    return error(message_id, -32601, f"method not found: {method}")


def run_stdio(root: str | None = None, config: str | None = None) -> int:
    print("rag-universal MCP server started", file=sys.stderr)
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
            response = handle_message(message, root, config)
        except Exception as exc:
            response = error(None, -32700, str(exc))
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0
