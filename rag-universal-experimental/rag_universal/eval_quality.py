from __future__ import annotations

import json
import posixpath
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .core import ensure_fresh_index, get_index_dir, load_chunks, load_config, load_json_list, resolve_root, search_index, tokenize

QUALITY_CHECK_VERSION = "rag.quality-check.v1"


def normalize_source_path(value: str) -> str:
    source = str(value).replace("\\", "/").strip()
    while source.startswith("./"):
        source = source[2:]
    normalized = posixpath.normpath(source)
    return "" if normalized == "." else normalized


def hit_rank(sources: list[str], expected_sources: list[str]) -> int | None:
    expected_set = {normalize_source_path(expected) for expected in expected_sources}
    for index, source in enumerate(sources, start=1):
        if normalize_source_path(source) in expected_set:
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
