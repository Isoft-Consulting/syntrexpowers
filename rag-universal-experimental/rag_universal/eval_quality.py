from __future__ import annotations

import json
import math
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .core import ensure_fresh_index, get_index_dir, load_chunks, load_config, load_json_list, resolve_root, search_index, search_index_with_plan, tokenize

QUALITY_CHECK_VERSION = "rag.quality-check.v1"
QUALITY_BENCHMARK_VERSION = "rag.quality-benchmark.v1"


def hit_rank(sources: list[str], expected_sources: list[str]) -> int | None:
    for index, source in enumerate(sources, start=1):
        if any(expected in source for expected in expected_sources):
            return index
    return None


def summarize_ranks(ranks: list[int | None]) -> dict[str, Any]:
    total = len(ranks)
    if total == 0:
        return {"total": 0, "top1": 0, "top3": 0, "top5": 0, "top10": 0, "mrr": 0.0}
    return {
        "total": total,
        "top1": sum(1 for rank in ranks if rank == 1),
        "top3": sum(1 for rank in ranks if rank is not None and rank <= 3),
        "top5": sum(1 for rank in ranks if rank is not None and rank <= 5),
        "top10": sum(1 for rank in ranks if rank is not None and rank <= 10),
        "mrr": round(sum((1.0 / rank) for rank in ranks if rank is not None) / total, 3),
    }


def load_baseline_corpus(root: Path, index_dir: Path) -> list[tuple[str, str]]:
    corpus: list[tuple[str, str]] = []
    for item in load_json_list(index_dir / "files.json"):
        source = str(item.get("source", ""))
        path = root / source
        try:
            text = path.read_text(encoding="utf-8", errors="replace").lower()
        except OSError:
            continue
        corpus.append((source, text))
    return corpus


def keyword_baseline(corpus: list[tuple[str, str]], query: str, top_k: int) -> list[str]:
    query_terms = [term for term in tokenize(query) if len(term) > 2]
    rows: list[tuple[int, int, str]] = []
    for source, lower in corpus:
        matched = 0
        score = 0
        for term in query_terms:
            count = lower.count(term)
            if count:
                matched += 1
                score += min(count, 8)
        if score:
            rows.append((matched, score, source))
    rows.sort(key=lambda row: (-row[0], -row[1], row[2]))
    return [source for _, _, source in rows[: max(1, min(int(top_k), 50))]]


def evaluate_quality(
    root_arg: str | Path | None,
    config_path: str | Path | None,
    cases_path: str | Path,
    top_k: int = 10,
    mode: str = "default",
    include_baseline: bool = True,
    include_cases: bool = True,
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    case_file = Path(cases_path)
    if not case_file.is_absolute():
        case_file = root / case_file
        if not case_file.exists():
            case_file = Path.cwd() / str(cases_path)
    cases = json.loads(case_file.read_text(encoding="utf-8"))

    baseline_corpus = load_baseline_corpus(root, index_dir) if include_baseline else []
    return evaluate_case_rows(root, config_path, cases, baseline_corpus, top_k, mode, include_baseline, include_cases)


def evaluate_case_rows(
    root: Path,
    config_path: str | Path | None,
    cases: list[dict[str, Any]],
    baseline_corpus: list[tuple[str, str]],
    top_k: int = 10,
    mode: str = "default",
    include_baseline: bool = True,
    include_cases: bool = True,
) -> dict[str, Any]:
    rag_ranks: list[int | None] = []
    baseline_ranks: list[int | None] = []
    details: list[dict[str, Any]] = []
    for case in cases:
        expected = [str(item) for item in case["expected_sources"]]
        rag_results = search_index(root, config_path, str(case["query"]), top_k=top_k, mode=mode)
        rag_sources = [str(item["source"]) for item in rag_results]
        baseline_sources = keyword_baseline(baseline_corpus, str(case["query"]), top_k=top_k) if include_baseline else []
        rag_rank = hit_rank(rag_sources, expected)
        baseline_rank = hit_rank(baseline_sources, expected) if include_baseline else None
        rag_ranks.append(rag_rank)
        if include_baseline:
            baseline_ranks.append(baseline_rank)
        if include_cases:
            details.append(
                {
                    "id": case.get("id"),
                    "query": case["query"],
                    "expected_sources": expected,
                    "rag_rank": rag_rank,
                    "baseline_rank": baseline_rank,
                    "rag_top": rag_sources[:3],
                    "baseline_top": baseline_sources[:3],
                }
            )

    rag = summarize_ranks(rag_ranks)
    baseline = summarize_ranks(baseline_ranks) if include_baseline else None
    summary: dict[str, Any] = {"rag": rag, "baseline": baseline}
    if baseline is not None:
        summary["delta"] = {
            "top1": rag["top1"] - baseline["top1"],
            "top3": rag["top3"] - baseline["top3"],
            "top5": rag["top5"] - baseline["top5"],
            "top10": rag["top10"] - baseline["top10"],
            "mrr": round(rag["mrr"] - baseline["mrr"], 3),
        }
    else:
        summary["delta"] = None
    return {"cases": details, "summary": summary}


def estimate_text_tokens(text: str) -> int:
    normalized = reflow_whitespace(text)
    if not normalized:
        return 0
    return max(1, math.ceil(len(normalized) / 4))


def reflow_whitespace(text: str) -> str:
    return " ".join(str(text).split())


def percentile(values: list[float], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    index = max(0, min(len(ordered) - 1, math.ceil(ratio * len(ordered)) - 1))
    return ordered[index]


def build_chunk_text_lookup(chunks: list[dict[str, Any]]) -> dict[tuple[str, int], str]:
    lookup: dict[tuple[str, int], str] = {}
    for chunk in chunks:
        source = str(chunk.get("source", ""))
        start_line = int(chunk.get("start_line", 1))
        if not source:
            continue
        lookup[(source, start_line)] = str(chunk.get("text", ""))
    return lookup


def estimate_read_plan_tokens(read_plan: dict[str, Any], chunk_lookup: dict[tuple[str, int], str]) -> int:
    total = 0
    for item in read_plan.get("items", []):
        source = str(item.get("source", ""))
        read_hint = str(item.get("read_hint", ""))
        start_line = 1
        match = read_hint.split(":", 1)
        if len(match) == 2:
            line_part = match[1].split(" ", 1)[0]
            try:
                start_line = int(line_part)
            except ValueError:
                start_line = 1
        total += estimate_text_tokens(chunk_lookup.get((source, start_line), ""))
    return total


def estimate_baseline_tokens(root: Path, baseline_sources: list[str]) -> int:
    total = 0
    for source in baseline_sources:
        path = root / source
        try:
            total += estimate_text_tokens(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    return total


def summarize_benchmark(latencies_ms: list[float], tokens: list[int], ranks: list[int | None]) -> dict[str, Any]:
    summary = summarize_ranks(ranks)
    summary.update(
        {
            "latency_ms_avg": round(sum(latencies_ms) / len(latencies_ms), 2) if latencies_ms else 0.0,
            "latency_ms_p50": round(percentile(latencies_ms, 0.5), 2),
            "latency_ms_p95": round(percentile(latencies_ms, 0.95), 2),
            "tokens_avg": round(sum(tokens) / len(tokens), 1) if tokens else 0.0,
            "tokens_p50": round(percentile([float(value) for value in tokens], 0.5), 1),
            "tokens_p95": round(percentile([float(value) for value in tokens], 0.95), 1),
        }
    )
    return summary


def benchmark_verdict(
    summary: dict[str, Any],
    min_cases: int,
    min_top3_ratio: float,
    min_mrr: float,
    max_latency_p95_ms: float,
    max_tokens_avg: float,
) -> dict[str, Any]:
    rag = summary["rag"]
    total = int(rag.get("total", 0))
    top3_ratio = (float(rag.get("top3", 0)) / total) if total else 0.0
    mrr = float(rag.get("mrr", 0.0))
    latency_p95 = float(rag.get("latency_ms_p95", 0.0))
    tokens_avg = float(rag.get("tokens_avg", 0.0))
    reasons: list[str] = []
    if total < min_cases:
        reasons.append(f"not enough benchmark cases: {total} < {min_cases}")
    if top3_ratio < min_top3_ratio:
        reasons.append(f"RAG Top-3 ratio below threshold: {top3_ratio:.3f} < {min_top3_ratio:.3f}")
    if mrr < min_mrr:
        reasons.append(f"RAG MRR below threshold: {mrr:.3f} < {min_mrr:.3f}")
    if latency_p95 > max_latency_p95_ms:
        reasons.append(f"RAG latency p95 above threshold: {latency_p95:.2f} > {max_latency_p95_ms:.2f}")
    if tokens_avg > max_tokens_avg:
        reasons.append(f"RAG tokens avg above threshold: {tokens_avg:.1f} > {max_tokens_avg:.1f}")
    return {
        "status": "pass" if not reasons else "fail",
        "reasons": reasons,
        "thresholds": {
            "min_cases": min_cases,
            "min_top3_ratio": min_top3_ratio,
            "min_mrr": min_mrr,
            "max_latency_p95_ms": max_latency_p95_ms,
            "max_tokens_avg": max_tokens_avg,
        },
        "observed": {
            "top3_ratio": round(top3_ratio, 3),
            "mrr": mrr,
            "latency_ms_p95": round(latency_p95, 2),
            "tokens_avg": round(tokens_avg, 1),
        },
    }


def resolve_benchmark_profile(
    config: dict[str, Any],
    mode: str,
    profile_name: str | None,
    min_cases: int,
    min_top3_ratio: float,
    min_mrr: float,
    max_latency_p95_ms: float,
    max_tokens_avg: float,
) -> dict[str, Any]:
    profiles_cfg = config.get("benchmark_profiles", {})
    available_profiles = profiles_cfg if isinstance(profiles_cfg, dict) and profiles_cfg else {}
    requested = str(profile_name or "auto").strip().lower()
    normalized_mode = str(mode or "default").strip().lower()
    if requested in {"", "auto"}:
        resolved_name = normalized_mode if normalized_mode in available_profiles else "default"
    else:
        resolved_name = requested if requested in available_profiles else "default"
    base = available_profiles.get(resolved_name, available_profiles.get("default", {}))
    return {
        "name": resolved_name,
        "thresholds": {
            "min_cases": int(min_cases) if min_cases != 5 else int(base["min_cases"]),
            "min_top3_ratio": float(min_top3_ratio) if min_top3_ratio != 0.6 else float(base["min_top3_ratio"]),
            "min_mrr": float(min_mrr) if min_mrr != 0.4 else float(base["min_mrr"]),
            "max_latency_p95_ms": float(max_latency_p95_ms) if max_latency_p95_ms != 20_000.0 else float(base["max_latency_p95_ms"]),
            "max_tokens_avg": float(max_tokens_avg) if max_tokens_avg != 5_000.0 else float(base["max_tokens_avg"]),
        },
    }


def benchmark_quality(
    root_arg: str | Path | None,
    config_path: str | Path | None,
    cases_path: str | Path,
    top_k: int = 5,
    mode: str = "default",
    include_baseline: bool = True,
    include_cases: bool = True,
    profile_name: str | None = None,
    min_cases: int = 5,
    min_top3_ratio: float = 0.6,
    min_mrr: float = 0.4,
    max_latency_p95_ms: float = 20_000.0,
    max_tokens_avg: float = 5_000.0,
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    case_file = Path(cases_path)
    if not case_file.is_absolute():
        case_file = root / case_file
        if not case_file.exists():
            case_file = Path.cwd() / str(cases_path)
    cases = json.loads(case_file.read_text(encoding="utf-8"))
    profile = resolve_benchmark_profile(config, mode, profile_name, min_cases, min_top3_ratio, min_mrr, max_latency_p95_ms, max_tokens_avg)
    thresholds = profile["thresholds"]
    baseline_corpus = load_baseline_corpus(root, index_dir) if include_baseline else []
    chunk_lookup = build_chunk_text_lookup(load_chunks(index_dir))

    rag_ranks: list[int | None] = []
    baseline_ranks: list[int | None] = []
    rag_latency_ms: list[float] = []
    baseline_latency_ms: list[float] = []
    rag_tokens: list[int] = []
    baseline_tokens: list[int] = []
    details: list[dict[str, Any]] = []

    for case in cases:
        query = str(case["query"])
        expected = [str(item) for item in case["expected_sources"]]
        case_mode = str(case.get("mode") or mode)

        started = time.perf_counter()
        rag_payload = search_index_with_plan(root, config_path, query, top_k=top_k, mode=case_mode)
        rag_elapsed = (time.perf_counter() - started) * 1000.0
        rag_sources = [str(item["source"]) for item in rag_payload["results"]]
        rag_rank = hit_rank(rag_sources, expected)
        rag_token_cost = estimate_read_plan_tokens(rag_payload.get("read_plan", {}), chunk_lookup)

        rag_ranks.append(rag_rank)
        rag_latency_ms.append(rag_elapsed)
        rag_tokens.append(rag_token_cost)

        baseline_sources: list[str] = []
        baseline_rank: int | None = None
        baseline_elapsed = 0.0
        baseline_token_cost = 0
        if include_baseline:
            started = time.perf_counter()
            baseline_sources = keyword_baseline(baseline_corpus, query, top_k=top_k)
            baseline_elapsed = (time.perf_counter() - started) * 1000.0
            baseline_rank = hit_rank(baseline_sources, expected)
            baseline_token_cost = estimate_baseline_tokens(root, baseline_sources)
            baseline_ranks.append(baseline_rank)
            baseline_latency_ms.append(baseline_elapsed)
            baseline_tokens.append(baseline_token_cost)

        if include_cases:
            details.append(
                {
                    "id": case.get("id"),
                    "query": query,
                    "expected_sources": expected,
                    "rag_rank": rag_rank,
                    "rag_top": rag_sources[:3],
                    "rag_latency_ms": round(rag_elapsed, 2),
                    "rag_tokens": rag_token_cost,
                    "baseline_rank": baseline_rank,
                    "baseline_top": baseline_sources[:3],
                    "baseline_latency_ms": round(baseline_elapsed, 2) if include_baseline else None,
                    "baseline_tokens": baseline_token_cost if include_baseline else None,
                }
            )

    rag_summary = summarize_benchmark(rag_latency_ms, rag_tokens, rag_ranks)
    baseline_summary = summarize_benchmark(baseline_latency_ms, baseline_tokens, baseline_ranks) if include_baseline else None
    summary: dict[str, Any] = {"rag": rag_summary, "baseline": baseline_summary}
    if baseline_summary is not None:
        summary["delta"] = {
            "top1": rag_summary["top1"] - baseline_summary["top1"],
            "top3": rag_summary["top3"] - baseline_summary["top3"],
            "top5": rag_summary["top5"] - baseline_summary["top5"],
            "top10": rag_summary["top10"] - baseline_summary["top10"],
            "mrr": round(rag_summary["mrr"] - baseline_summary["mrr"], 3),
            "latency_ms_avg": round(rag_summary["latency_ms_avg"] - baseline_summary["latency_ms_avg"], 2),
            "tokens_avg": round(rag_summary["tokens_avg"] - baseline_summary["tokens_avg"], 1),
        }
    else:
        summary["delta"] = None
    return {
        "schema_version": QUALITY_BENCHMARK_VERSION,
        "cases": details,
        "benchmark_profile": profile["name"],
        "summary": summary,
        "verdict": benchmark_verdict(
            summary,
            int(thresholds["min_cases"]),
            float(thresholds["min_top3_ratio"]),
            float(thresholds["min_mrr"]),
            float(thresholds["max_latency_p95_ms"]),
            float(thresholds["max_tokens_avg"]),
        ),
    }


def unique_ordered(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item not in seen:
            out.append(item)
            seen.add(item)
    return out


def generated_query_terms(chunk: dict[str, Any], stopwords: set[str]) -> list[str]:
    source = str(chunk.get("source", ""))
    heading = str(chunk.get("heading", ""))
    text = str(chunk.get("text", ""))
    path_terms = [term for term in tokenize(source.replace("/", " ")) if len(term) > 2]
    heading_terms = [term for term in tokenize(heading) if len(term) > 2]
    counts = Counter(term for term in tokenize(text) if len(term) > 2 and term not in stopwords and not term.isdigit())
    common_terms = [term for term, _ in counts.most_common(12)]
    return unique_ordered(path_terms[-4:] + heading_terms[:6] + common_terms)


def generate_quality_cases(
    root_arg: str | Path | None,
    config_path: str | Path | None,
    limit: int = 25,
) -> list[dict[str, Any]]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    chunks = load_chunks(get_index_dir(root, config))
    stopwords = set(str(item).lower() for item in config.get("search", {}).get("query_stopwords", []))
    by_role: dict[str, list[dict[str, Any]]] = defaultdict(list)
    seen_sources: set[str] = set()
    for chunk in chunks:
        source = str(chunk.get("source", ""))
        if not source or source in seen_sources:
            continue
        terms = generated_query_terms(chunk, stopwords)
        if len(terms) < 3:
            continue
        role = str(chunk.get("fdr_role") or chunk.get("artifact_type") or "other")
        by_role[role].append(
            {
                "id": f"generated-{len(seen_sources) + 1}",
                "query": " ".join(terms[:8]),
                "expected_sources": [source],
                "source": source,
                "role": role,
                "generated": True,
            }
        )
        seen_sources.add(source)

    cases: list[dict[str, Any]] = []
    role_order = ["plan", "spec", "docs", "implementation", "test", "config", "build_file", "ignore_config", "compose_config", "other"]
    while len(cases) < max(1, limit):
        added = False
        for role in role_order + sorted(set(by_role) - set(role_order)):
            rows = by_role.get(role, [])
            if rows:
                cases.append(rows.pop(0))
                added = True
                if len(cases) >= max(1, limit):
                    break
        if not added:
            break
    for index, case in enumerate(cases, start=1):
        case["id"] = f"generated-{index}"
    return cases


def quality_verdict(summary: dict[str, Any], index_stale: bool, min_cases: int, min_top3_ratio: float, min_mrr: float) -> dict[str, Any]:
    rag = summary["rag"]
    total = int(rag.get("total", 0))
    top3_ratio = (float(rag.get("top3", 0)) / total) if total else 0.0
    mrr = float(rag.get("mrr", 0.0))
    reasons: list[str] = []
    if index_stale:
        reasons.append("index is stale after quality check")
    if total < min_cases:
        reasons.append(f"not enough generated/eval cases: {total} < {min_cases}")
    if top3_ratio < min_top3_ratio:
        reasons.append(f"RAG Top-3 ratio below threshold: {top3_ratio:.3f} < {min_top3_ratio:.3f}")
    if mrr < min_mrr:
        reasons.append(f"RAG MRR below threshold: {mrr:.3f} < {min_mrr:.3f}")
    return {
        "status": "pass" if not reasons else "fail",
        "reasons": reasons,
        "thresholds": {
            "min_cases": min_cases,
            "min_top3_ratio": min_top3_ratio,
            "min_mrr": min_mrr,
        },
        "observed": {
            "top3_ratio": round(top3_ratio, 3),
            "mrr": mrr,
        },
    }


def quality_check(
    root_arg: str | Path | None,
    config_path: str | Path | None,
    cases_path: str | Path | None = None,
    case_limit: int = 25,
    top_k: int = 10,
    mode: str = "default",
    auto_reindex: bool = False,
    include_cases: bool = True,
    min_cases: int = 5,
    min_top3_ratio: float = 0.6,
    min_mrr: float = 0.4,
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    freshness = ensure_fresh_index(root, config_path, auto_reindex)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    if cases_path is not None:
        case_file = Path(cases_path)
        if not case_file.is_absolute():
            case_file = root / case_file
            if not case_file.exists():
                case_file = Path.cwd() / str(cases_path)
        cases = json.loads(case_file.read_text(encoding="utf-8"))
        case_source = str(case_file)
    else:
        cases = generate_quality_cases(root, config_path, case_limit)
        case_source = "generated-from-index"
    baseline_corpus = load_baseline_corpus(root, index_dir)
    evaluation = evaluate_case_rows(root, config_path, cases, baseline_corpus, top_k, mode, True, include_cases)
    stale_after = bool(freshness.get("status", {}).get("stale"))
    verdict = quality_verdict(evaluation["summary"], stale_after, min_cases, min_top3_ratio, min_mrr)
    return {
        "schema_version": QUALITY_CHECK_VERSION,
        "mode": mode,
        "top_k": top_k,
        "case_source": case_source,
        "case_limit": case_limit if cases_path is None else None,
        "health": {
            "index_exists": bool(freshness.get("status", {}).get("exists")),
            "index_stale_before_check": bool(freshness.get("stale_before")),
            "index_reindexed": bool(freshness.get("reindexed")),
            "index_stale_after_check": stale_after,
            "cases": len(cases),
            "baseline": "keyword",
        },
        "summary": evaluation["summary"],
        "verdict": verdict,
        "cases": evaluation["cases"],
    }
