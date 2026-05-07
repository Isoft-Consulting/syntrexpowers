from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .core import get_index_dir, load_config, load_json_list, resolve_root, search_index, tokenize


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

    rag_ranks: list[int | None] = []
    baseline_ranks: list[int | None] = []
    details: list[dict[str, Any]] = []
    baseline_corpus = load_baseline_corpus(root, index_dir) if include_baseline else []
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
                    "id": case["id"],
                    "query": case["query"],
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
