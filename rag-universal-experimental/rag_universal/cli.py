from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from .core import (
    build_index,
    index_coverage,
    index_status,
    load_config,
    lookup_deps,
    lookup_symbol,
    resolve_root,
    search_index,
    search_index_with_plan,
    watch_index,
)
from .eval_quality import benchmark_quality, evaluate_quality, quality_check
from .knowledge import build_project_knowledge, generate_project_profile
from .mcp_server import run_stdio


def emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Universal local RAG toolkit")
    parser.add_argument("--root", default=".", help="Project root. Default: current directory.")
    parser.add_argument("--config", default=None, help="Config path relative to root, current directory, or absolute path.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    index = subparsers.add_parser("index", help="Build the local RAG index")
    index.add_argument(
        "--incremental",
        action="store_true",
        help="Refresh only changed/deleted sources when the existing index is compatible. This is the CLI default; kept for compatibility.",
    )
    index.add_argument("--full-rebuild", action="store_true", help="Disable incremental planning and rebuild the full index.")
    subparsers.add_parser("status", help="Show local RAG index status")
    coverage = subparsers.add_parser("coverage", help="Report whether specific paths are indexed")
    coverage.add_argument("paths", nargs="+")

    search = subparsers.add_parser("search", help="Search the local RAG index")
    search.add_argument("query")
    search.add_argument("--top-k", type=int, default=5)
    search.add_argument("--filter-source", default=None)
    search.add_argument("--filter-type", default=None)
    search.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"], default="default")
    search.add_argument("--with-plan", action="store_true", help="Return results with a section-level read plan.")
    search.add_argument(
        "--economy",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Override search budget mode (default comes from search.default_budget in rag config). Omit for default.",
    )
    search.add_argument(
        "--auto-reindex",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Rebuild the index before searching when rag_status reports stale source files. Omit to use cli.auto_reindex_default.",
    )

    watch = subparsers.add_parser("watch", help="Poll source files and rebuild the index when it becomes stale")
    watch.add_argument("--interval", type=float, default=2.0, help="Polling interval in seconds for continuous watch mode.")
    watch.add_argument("--debounce", type=float, default=1.0, help="Delay before rebuild after a stale check.")
    watch.add_argument("--max-cycles", type=int, default=0, help="Stop after N polling cycles. Default 0 means run until interrupted.")
    watch.add_argument("--full-rebuild", action="store_true", help="Disable incremental refresh and always rebuild from scratch.")

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
    eval_quality.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"], default="default")
    eval_quality.add_argument("--skip-baseline", action="store_true", help="Skip keyword baseline; useful for large path-focused gold sets.")
    eval_quality.add_argument("--summary-only", action="store_true", help="Omit per-case details from output.")

    benchmark = subparsers.add_parser("benchmark-quality", help="Benchmark RAG retrieval latency and token budget against keyword baseline")
    benchmark.add_argument("--cases", required=True, help="Gold query JSON file.")
    benchmark.add_argument("--top-k", type=int, default=5)
    benchmark.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"], default="default")
    benchmark.add_argument("--profile", choices=["auto", "default", "frontend", "implementation", "knowledge", "self-rag"], default="auto")
    benchmark.add_argument("--skip-baseline", action="store_true", help="Skip keyword baseline.")
    benchmark.add_argument("--summary-only", action="store_true", help="Omit per-case details from output.")
    benchmark.add_argument("--min-cases", type=int, default=5)
    benchmark.add_argument("--min-top3-ratio", type=float, default=0.6)
    benchmark.add_argument("--min-mrr", type=float, default=0.4)
    benchmark.add_argument("--max-latency-p95-ms", type=float, default=20000.0)
    benchmark.add_argument("--max-tokens-avg", type=float, default=5000.0)

    quality = subparsers.add_parser("quality-check", help="Run RAG health and comparative quality metrics")
    quality.add_argument("--cases", default=None, help="Optional gold query JSON file. If omitted, cases are generated from the current index.")
    quality.add_argument("--case-limit", type=int, default=25, help="Maximum generated cases when --cases is omitted.")
    quality.add_argument("--top-k", type=int, default=10)
    quality.add_argument("--mode", choices=["default", "fdr", "architecture", "implementation", "frontend", "migration", "knowledge"], default="default")
    quality.add_argument(
        "--auto-reindex",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Rebuild first when rag_status reports stale source files. Omit to use cli.auto_reindex_default.",
    )
    quality.add_argument("--summary-only", action="store_true", help="Omit per-case details from output.")
    quality.add_argument("--min-cases", type=int, default=5)
    quality.add_argument("--min-top3-ratio", type=float, default=0.6)
    quality.add_argument("--min-mrr", type=float, default=0.4)

    knowledge = subparsers.add_parser("knowledge-build", help="Build normalized RAG knowledge pack from review/eval cases")
    knowledge.add_argument("--cases", required=True, help="Gold/review cases JSON file.")
    knowledge.add_argument("--output", default="Docs/knowledge/rag", help="Output directory relative to root unless absolute.")
    knowledge.add_argument("--project", default="project", help="Project name used in summary metadata.")
    knowledge.add_argument("--rules", default=None, help="Optional project-specific knowledge rules JSON.")

    knowledge_status = subparsers.add_parser("knowledge-status", help="Report whether a generated knowledge pack is stale against its cases/rules inputs")
    knowledge_status.add_argument("--summary", default="Docs/knowledge/rag/summary.json", help="Summary file or pack directory relative to root unless absolute.")

    profile = subparsers.add_parser("knowledge-profile", help="Generate a starter project-specific knowledge rules profile")
    profile.add_argument("--output", default="rag.knowledge.json", help="Output rules file relative to root unless absolute.")
    profile.add_argument("--project", default="project", help="Project name used in profile metadata.")

    serve_mcp = subparsers.add_parser("serve-mcp", help="Run MCP stdio server")
    serve_mcp.add_argument(
        "--cache-storage",
        choices=["disk", "memory"],
        default="disk",
        help="MCP-only SQLite search cache storage. Use memory only for long-lived MCP processes.",
    )
    serve_mcp.add_argument(
        "--require-explicit-root",
        action="store_true",
        help="Fail before starting MCP stdio unless --root was provided explicitly.",
    )
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


def cli_auto_reindex_default(config_data: dict[str, Any]) -> bool:
    cli_config = config_data.get("cli")
    if isinstance(cli_config, dict):
        value = cli_config.get("auto_reindex_default")
        if isinstance(value, bool):
            return value
    return False


def resolve_cli_auto_reindex(value: bool | None, root: str, config: str | None) -> bool:
    if value is not None:
        return bool(value)
    return cli_auto_reindex_default(load_config(resolve_root(root), config))


def main(argv: list[str] | None = None) -> int:
    raw_args = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(normalize_global_args(raw_args))
    if args.command == "index":
        emit(build_index(args.root, args.config, incremental=not bool(args.full_rebuild)))
        return 0
    if args.command == "status":
        emit(index_status(args.root, args.config))
        return 0
    if args.command == "coverage":
        emit(index_coverage(args.root, args.config, args.paths))
        return 0
    if args.command == "search":
        auto_reindex = resolve_cli_auto_reindex(args.auto_reindex, args.root, args.config)
        if args.with_plan:
            emit(
                search_index_with_plan(
                    args.root,
                    args.config,
                    args.query,
                    args.top_k,
                    args.filter_source,
                    args.filter_type,
                    args.mode,
                    auto_reindex=auto_reindex,
                    economy=args.economy,
                )
            )
        else:
            emit(
                search_index(
                    args.root,
                    args.config,
                    args.query,
                    args.top_k,
                    args.filter_source,
                    args.filter_type,
                    args.mode,
                    auto_reindex,
                    economy=args.economy,
                )
            )
        return 0
    if args.command == "watch":
        try:
            emit(
                watch_index(
                    args.root,
                    args.config,
                    args.interval,
                    args.debounce,
                    args.max_cycles or None,
                    prefer_incremental=not bool(args.full_rebuild),
                )
            )
        except KeyboardInterrupt:
            emit(index_status(args.root, args.config))
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
    if args.command == "benchmark-quality":
        emit(
            benchmark_quality(
                args.root,
                args.config,
                args.cases,
                args.top_k,
                args.mode,
                not args.skip_baseline,
                not args.summary_only,
                args.profile,
                args.min_cases,
                args.min_top3_ratio,
                args.min_mrr,
                args.max_latency_p95_ms,
                args.max_tokens_avg,
            )
        )
        return 0
    if args.command == "quality-check":
        auto_reindex = resolve_cli_auto_reindex(args.auto_reindex, args.root, args.config)
        emit(
            quality_check(
                args.root,
                args.config,
                args.cases,
                args.case_limit,
                args.top_k,
                args.mode,
                auto_reindex,
                not args.summary_only,
                args.min_cases,
                args.min_top3_ratio,
                args.min_mrr,
            )
        )
        return 0
    if args.command == "knowledge-build":
        emit(build_project_knowledge(args.root, args.cases, args.output, args.project, args.rules))
        return 0
    if args.command == "knowledge-status":
        from .knowledge import knowledge_pack_status

        emit(knowledge_pack_status(args.root, args.summary))
        return 0
    if args.command == "knowledge-profile":
        emit(generate_project_profile(args.root, args.output, args.project))
        return 0
    if args.command == "serve-mcp":
        if args.require_explicit_root and "--root" not in raw_args:
            print("rag.py serve-mcp requires explicit --root when --require-explicit-root is set", file=sys.stderr)
            return 2
        return run_stdio(args.root, args.config, args.cache_storage)
    raise RuntimeError(f"unhandled command: {args.command}")
