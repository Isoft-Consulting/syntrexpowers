#!/usr/bin/env python3
"""Regression guard: compare current RAG metrics against BASELINE_v1.json.

Usage:
    cd /var/www/core/.mcp/rag-server
    python3 evals/check_regression.py

Returns exit code 0 if all guards pass, 1 if any regression detected.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

# Ensure the rag_universal package is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from rag_universal.eval_quality import benchmark_quality
from rag_universal.core import (
    _FRESHNESS_CACHE,
    _PERF_TIMINGS,
    resolve_root,
    get_index_dir,
    load_config,
    load_chunks,
    search_index_with_plan,
)
from rag_universal.eval_quality import (
    load_baseline_corpus,
    keyword_baseline,
    estimate_baseline_tokens,
    estimate_read_plan_tokens,
    build_chunk_text_lookup,
)

BASELINE_PATH = Path(__file__).resolve().parent / "BASELINE_v1.json"
ROOT = "/var/www/core"


def load_baseline() -> dict[str, Any]:
    return json.loads(BASELINE_PATH.read_text(encoding="utf-8"))


def check_corpus(baseline: dict[str, Any]) -> list[str]:
    """Run corpus benchmarks and verify against baseline guards."""
    violations: list[str] = []
    guards = baseline["regression_guards"]["corpus_mrr_min"]
    top1_guards = baseline["regression_guards"]["corpus_top1_min"]
    latency_guard = baseline["regression_guards"]["latency"]["rag_p95_max_ms"]

    for corpus_key, corpus_config in [
        ("frontend", ("core-leonextra-fresh-frontend-prs-v1.json", "frontend", "frontend")),
        ("backend", ("core-leonextra-fresh-merged-prs-v1.json", "implementation", "implementation")),
    ]:
        cases_file, mode, profile = corpus_config
        _FRESHNESS_CACHE.clear()
        _PERF_TIMINGS.clear()

        t0 = time.perf_counter()
        result = benchmark_quality(ROOT, None, f"evals/{cases_file}", top_k=5, mode=mode, profile_name=profile)
        wall = time.perf_counter() - t0

        summary = result["summary"]["rag"]
        mrr = summary["mrr"]
        top1 = summary["top1"]
        p95 = summary["latency_ms_p95"]

        baseline_mrr = baseline["corpora"][corpus_key]["rag"]["mrr"]
        baseline_top1 = baseline["corpora"][corpus_key]["rag"]["top1"]
        min_mrr = guards[corpus_key]
        min_top1 = top1_guards[corpus_key]

        if mrr < min_mrr:
            violations.append(
                f"[{corpus_key}] MRR {mrr:.3f} < guard {min_mrr:.3f} (baseline={baseline_mrr:.3f})"
            )
        if top1 < min_top1:
            violations.append(
                f"[{corpus_key}] Top-1 {top1} < guard {min_top1} (baseline={baseline_top1})"
            )
        if p95 > latency_guard:
            violations.append(
                f"[{corpus_key}] Latency p95 {p95:.0f}ms > guard {latency_guard:.0f}ms"
            )
        if wall > baseline["regression_guards"]["latency"]["wall_seconds_max"]:
            violations.append(
                f"[{corpus_key}] Wall time {wall:.0f}s > guard {baseline['regression_guards']['latency']['wall_seconds_max']:.0f}s"
            )

        status = (
            f"[{corpus_key}] MRR={mrr:.3f} Top-1={top1}/{summary['total']}"
            f" p95={p95:.0f}ms wall={wall:.0f}s"
            f" (ΔMRR={mrr - baseline_mrr:+.3f}, ΔTop-1={top1 - baseline_top1:+d})"
        )
        print(f"  {status}")

    return violations


def check_manual_queries(baseline: dict[str, Any]) -> list[str]:
    """Run PR#88 manual queries and verify against baseline."""
    violations: list[str] = []
    guards = baseline["regression_guards"]["manual_queries"]
    min_mrr = guards["rag_mrr_min"]
    min_top1 = guards["rag_top1_min"]

    root = resolve_root(ROOT)
    config = load_config(root, None)
    index_dir = get_index_dir(root, config)
    corpus = load_baseline_corpus(root, index_dir)
    source_texts = {src: txt for src, txt in corpus}
    chunks = load_chunks(index_dir)
    chunk_lookup = build_chunk_text_lookup(chunks)

    ranks = []
    top1_count = 0
    spec_improvements = []

    for q in baseline["manual_queries_pr88"]["queries"]:
        qid = q["id"]
        expected = q["expected"]
        baseline_rank = q["rag_rank"]

        _FRESHNESS_CACHE.clear()
        rag = search_index_with_plan(ROOT, None, qid, top_k=5, mode="implementation")
        rag_sources = [it["source"] for it in rag["results"]]
        current_rank = next(
            (i + 1 for i, s in enumerate(rag_sources) if any(e in s for e in expected)),
            None,
        )
        ranks.append(current_rank)
        if current_rank == 1:
            top1_count += 1

        if qid in ("Q1_error_codes", "Q3_cap_snap"):
            if current_rank is not None and current_rank <= 3:
                spec_improvements.append(f"{qid}: rank {current_rank} (was null) — IMPROVED")
            elif current_rank is None and baseline_rank is None:
                pass  # neither improved nor regressed
            elif current_rank is not None and baseline_rank is not None and current_rank <= baseline_rank:
                pass  # no regression
            elif current_rank is None and baseline_rank is not None:
                violations.append(f"[manual] {qid}: regressed rank null (was {baseline_rank})")

        status = f"[{qid}] rank={current_rank} (was {baseline_rank})"
        if current_rank == baseline_rank:
            status += " — same"
        elif current_rank is not None and baseline_rank is not None and current_rank < baseline_rank:
            status += " — IMPROVED"
        elif current_rank is not None and baseline_rank is None:
            status += " — IMPROVED (was null)"
        elif current_rank is None and baseline_rank is not None:
            status += " — REGRESSION"
        print(f"  {status}")

    mrr = sum(1.0 / r if r else 0 for r in ranks) / len(ranks) if ranks else 0.0
    baseline_mrr = baseline["manual_queries_pr88"]["summary"]["rag_mrr"]

    if mrr < min_mrr:
        violations.append(
            f"[manual] MRR {mrr:.4f} < guard {min_mrr:.4f} (baseline={baseline_mrr:.4f})"
        )
    if top1_count < min_top1:
        violations.append(
            f"[manual] Top-1 {top1_count} < guard {min_top1}"
        )

    print(f"  [manual] MRR={mrr:.4f} Top-1={top1_count}/{len(ranks)} (ΔMRR={mrr - baseline_mrr:+.4f})")
    for imp in spec_improvements:
        print(f"  {imp}")

    return violations


def main() -> int:
    if not BASELINE_PATH.exists():
        print(f"BASELINE file not found: {BASELINE_PATH}", file=sys.stderr)
        print("Run from .mcp/rag-server/ directory", file=sys.stderr)
        return 2

    baseline = load_baseline()
    print(f"Regression check against {BASELINE_PATH.name} ({baseline['created_at']})")
    print()

    print("--- Corpus benchmarks ---")
    violations = check_corpus(baseline)

    print()
    print("--- PR#88 manual queries ---")
    violations.extend(check_manual_queries(baseline))

    print()
    if violations:
        print(f"REGRESSION DETECTED ({len(violations)} violations):")
        for v in violations:
            print(f"  ❌ {v}")
        return 1
    else:
        print("✅ ALL GUARDS PASS — no regressions detected")
        return 0


if __name__ == "__main__":
    sys.exit(main())
