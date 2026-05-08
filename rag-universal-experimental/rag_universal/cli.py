from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from .core import build_index, index_coverage, index_status, lookup_deps, lookup_symbol, search_index, search_index_with_plan
from .eval_quality import evaluate_quality
from .knowledge import build_project_knowledge
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
    coverage = subparsers.add_parser("coverage", help="Report whether specific paths are indexed")
    coverage.add_argument("paths", nargs="+")

    search = subparsers.add_parser("search", help="Search the local RAG index")
    search.add_argument("query")
    search.add_argument("--top-k", type=int, default=5)
    search.add_argument("--filter-source", default=None)
    search.add_argument("--filter-type", default=None)
    search.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration"], default="default")
    search.add_argument("--with-plan", action="store_true", help="Return results with a section-level read plan.")

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
    eval_quality.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration"], default="default")
    eval_quality.add_argument("--skip-baseline", action="store_true", help="Skip keyword baseline; useful for large path-focused gold sets.")
    eval_quality.add_argument("--summary-only", action="store_true", help="Omit per-case details from output.")

    knowledge = subparsers.add_parser("knowledge-build", help="Build normalized RAG knowledge pack from review/eval cases")
    knowledge.add_argument("--cases", required=True, help="Gold/review cases JSON file.")
    knowledge.add_argument("--output", default="Docs/knowledge/rag", help="Output directory relative to root unless absolute.")
    knowledge.add_argument("--project", default="project", help="Project name used in summary metadata.")
    knowledge.add_argument("--rules", default=None, help="Optional project-specific knowledge rules JSON.")

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
    if args.command == "coverage":
        emit(index_coverage(args.root, args.config, args.paths))
        return 0
    if args.command == "search":
        if args.with_plan:
            emit(search_index_with_plan(args.root, args.config, args.query, args.top_k, args.filter_source, args.filter_type, args.mode))
        else:
            emit(search_index(args.root, args.config, args.query, args.top_k, args.filter_source, args.filter_type, args.mode))
        return 0
    if args.command == "symbol":
        emit(lookup_symbol(args.root, args.config, args.name, args.kind, args.limit))
        return 0
    if args.command == "deps":
        emit(lookup_deps(args.root, args.config, args.target, args.direction, args.limit))
        return 0
    if args.command == "eval-quality":
        emit(evaluate_quality(args.root, args.config, args.cases, args.top_k, args.mode, not args.skip_baseline, not args.summary_only))
        return 0
    if args.command == "knowledge-build":
        emit(build_project_knowledge(args.root, args.cases, args.output, args.project, args.rules))
        return 0
    if args.command == "serve-mcp":
        return run_stdio(args.root, args.config)
    raise RuntimeError(f"unhandled command: {args.command}")
