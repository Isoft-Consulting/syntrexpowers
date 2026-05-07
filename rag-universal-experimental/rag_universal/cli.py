from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from .core import build_index, index_status, lookup_deps, lookup_symbol, search_index
from .eval_quality import evaluate_quality
from .mcp_server import run_stdio


def emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Universal local RAG toolkit")
    parser.add_argument("--root", default=".", help="Project root. Default: current directory.")
    parser.add_argument("--config", default=None, help="Config path relative to root, current directory, or absolute path.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("index", help="Build the local RAG index")
    subparsers.add_parser("status", help="Show local RAG index status")

    search = subparsers.add_parser("search", help="Search the local RAG index")
    search.add_argument("query")
    search.add_argument("--top-k", type=int, default=5)
    search.add_argument("--filter-source", default=None)
    search.add_argument("--filter-type", default=None)

    symbol = subparsers.add_parser("symbol", help="Look up exact symbols")
    symbol.add_argument("name")
    symbol.add_argument("--kind", default=None)
    symbol.add_argument("--limit", type=int, default=20)

    deps = subparsers.add_parser("deps", help="Look up dependency edges")
    deps.add_argument("target")
    deps.add_argument("--direction", choices=["reverse", "forward"], default="reverse")
    deps.add_argument("--limit", type=int, default=20)

    eval_quality = subparsers.add_parser("eval-quality", help="Compare RAG retrieval against keyword baseline")
    eval_quality.add_argument("--cases", required=True, help="Gold query JSON file.")
    eval_quality.add_argument("--top-k", type=int, default=10)

    subparsers.add_parser("serve-mcp", help="Run MCP stdio server")
    return parser


def normalize_global_args(argv: list[str] | None) -> list[str]:
    source = list(sys.argv[1:] if argv is None else argv)
    extracted: list[str] = []
    remaining: list[str] = []
    index = 0
    while index < len(source):
        item = source[index]
        if item in ("--root", "--config"):
            if index + 1 >= len(source):
                remaining.append(item)
                index += 1
                continue
            extracted.extend([item, source[index + 1]])
            index += 2
            continue
        remaining.append(item)
        index += 1
    return extracted + remaining


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(normalize_global_args(argv))
    if args.command == "index":
        emit(build_index(args.root, args.config))
        return 0
    if args.command == "status":
        emit(index_status(args.root, args.config))
        return 0
    if args.command == "search":
        emit(search_index(args.root, args.config, args.query, args.top_k, args.filter_source, args.filter_type))
        return 0
    if args.command == "symbol":
        emit(lookup_symbol(args.root, args.config, args.name, args.kind, args.limit))
        return 0
    if args.command == "deps":
        emit(lookup_deps(args.root, args.config, args.target, args.direction, args.limit))
        return 0
    if args.command == "eval-quality":
        emit(evaluate_quality(args.root, args.config, args.cases, args.top_k))
        return 0
    if args.command == "serve-mcp":
        return run_stdio(args.root, args.config)
    raise RuntimeError(f"unhandled command: {args.command}")
