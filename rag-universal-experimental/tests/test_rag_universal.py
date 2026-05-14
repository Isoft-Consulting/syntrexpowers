from __future__ import annotations

import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rag_universal.core import (
    allow_frontend_high_confidence_result,
    build_read_plan,
    build_index,
    build_query_variants,
    chunk_role,
    close_search_cache_connections,
    configure_search_cache_storage,
    ensure_fresh_index,
    fuse_ranked_results,
    get_index_dir,
    index_coverage,
    index_status,
    intent_source_multiplier,
    load_chunks,
    load_config,
    load_search_cache,
    profile_result_sort_key,
    query_role_bias_multiplier,
    read_hint_with_role,
    read_plan_role_rank,
    score_query_profile,
    section_anchor_multiplier,
    source_preview_chars,
    lookup_deps,
    lookup_symbol,
    search_index,
    search_index_with_plan,
    search_cache_storage_mode,
    split_large_text,
    select_search_results,
    tokenize,
    token_counts,
    trim_query_counts,
    watch_index,
)
from rag_universal.eval_quality import benchmark_quality
from rag_universal.eval_quality import evaluate_case_rows
from rag_universal.eval_quality import evaluate_quality
from rag_universal.eval_quality import generated_query_terms
from rag_universal.eval_quality import quality_check
from rag_universal.eval_quality import resolve_benchmark_profile
from rag_universal.knowledge import build_project_knowledge
from rag_universal.knowledge import generate_project_profile
from rag_universal.knowledge import knowledge_pack_status
from rag_universal.cli import cli_auto_reindex_default
from rag_universal.cli import resolve_cli_auto_reindex
from rag_universal.mcp_server import handle_message
from rag_universal.mcp_server import mcp_auto_reindex_default
from rag_universal.mcp_server import mcp_require_explicit_root_default
from rag_universal.mcp_server import resolve_mcp_auto_reindex
from rag_universal.mcp_server import resolve_mcp_require_explicit_root
from rag_universal.mcp_server import tool_definitions


class RagUniversalTest(unittest.TestCase):
    def make_project(self) -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "README.md").write_text(
            "# Demo\n\nStrict mode stop guard blocks unfinished work.\n\n## Install\n\nRun the hook installer.",
            encoding="utf-8",
        )
        (root / "src").mkdir()
        (root / "src" / "service.py").write_text(
            "import json\n\nclass StrictGuard:\n    def stop_guard(self):\n        return json.dumps({'ok': True})\n",
            encoding="utf-8",
        )
        (root / "src" / "Sql.php").write_text(
            "<?php\n\nnamespace App\\Support;\n\nfinal class Sql\n{\n}\n",
            encoding="utf-8",
        )
        (root / "schemas").mkdir()
        (root / "schemas" / "demo.schema.json").write_text(
            json.dumps({"$id": "demo.schema.v1", "title": "Demo Schema"}),
            encoding="utf-8",
        )
        (root / ".env").write_text("API_TOKEN=should-not-be-indexed", encoding="utf-8")
        (root / ".mcp.json").write_text('{"authorization":"Bearer should-not-be-indexed"}', encoding="utf-8")
        (root / "node_modules").mkdir()
        (root / "node_modules" / "ignored.md").write_text("ignored dependency docs", encoding="utf-8")
        (root / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
        (root / ".dockerignore").write_text(".env\n**/.env*\n", encoding="utf-8")
        return root

    def test_index_excludes_secret_paths_and_generates_artifacts(self) -> None:
        root = self.make_project()
        manifest = build_index(root)
        self.assertEqual(manifest["num_files"], 6)
        self.assertGreaterEqual(manifest["num_chunks"], 3)
        chunks = load_chunks(root / ".rag-index")
        sources = {chunk["source"] for chunk in chunks}
        self.assertIn("README.md", sources)
        self.assertIn("src/service.py", sources)
        self.assertIn("src/Sql.php", sources)
        self.assertIn("Dockerfile", sources)
        self.assertIn(".dockerignore", sources)
        self.assertNotIn(".env", sources)
        self.assertNotIn(".mcp.json", sources)
        self.assertFalse(any("should-not-be-indexed" in chunk["text"] for chunk in chunks))
        self.assertTrue((root / ".rag-index" / "manifest.json").exists())
        self.assertTrue((root / ".rag-index" / "search.sqlite").exists())
        self.assertTrue((root / ".rag-index" / "lexicon.json").exists())
        self.assertEqual(manifest["artifacts"]["search_cache"], "search.sqlite")

    def test_search_symbol_and_deps(self) -> None:
        root = self.make_project()
        build_index(root)
        results = search_index(root, None, "strict stop guard", top_k=3)
        self.assertTrue(results)
        self.assertEqual(results[0]["source"], "README.md")

        symbols = lookup_symbol(root, None, "StrictGuard")
        self.assertEqual(symbols[0]["source"], "src/service.py")
        self.assertEqual([symbol["kind"] for symbol in symbols], ["python_class"])

        schema_symbols = lookup_symbol(root, None, "demo.schema.v1")
        self.assertEqual(schema_symbols[0]["kind"], "json_schema_id")

        php_symbols = lookup_symbol(root, None, "Sql")
        self.assertEqual(php_symbols[0]["source"], "src/Sql.php")
        self.assertEqual(php_symbols[0]["kind"], "php_symbol")

        deps = lookup_deps(root, None, "json", direction="reverse")
        self.assertEqual(deps[0]["source"], "src/service.py")

    def test_search_falls_back_to_chunk_scan_when_sqlite_cache_is_unreadable(self) -> None:
        root = self.make_project()
        build_index(root)
        with mock.patch("rag_universal.core.load_search_cache") as mocked_cache, mock.patch(
            "rag_universal.core.search_precomputed_cache",
            side_effect=sqlite3.DatabaseError("database disk image is malformed"),
        ):
            mocked_cache.return_value = object()
            results = search_index(root, None, "strict stop guard", top_k=1)
        self.assertEqual(results[0]["source"], "README.md")

    def test_load_search_cache_returns_none_for_corrupt_sqlite_file(self) -> None:
        root = self.make_project()
        build_index(root)
        index_dir = get_index_dir(root, load_config(root, None))
        close_search_cache_connections(index_dir)
        (index_dir / "search.sqlite").write_text("not a sqlite database", encoding="utf-8")
        self.assertIsNone(load_search_cache(index_dir))

    def test_search_repairs_corrupt_sqlite_cache_before_fallback(self) -> None:
        root = self.make_project()
        build_index(root)
        index_dir = get_index_dir(root, load_config(root, None))
        close_search_cache_connections(index_dir)
        (index_dir / "search.sqlite").write_text("not a sqlite database", encoding="utf-8")
        results = search_index(root, None, "strict stop guard", top_k=1)
        self.assertEqual(results[0]["source"], "README.md")
        self.assertIsNotNone(load_search_cache(index_dir))

    def test_build_query_variants_includes_anchor_and_compact_focus_terms(self) -> None:
        root = self.make_project()
        config_path = root / ".mcp" / "rag-server" / "rag.config.json"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text("{}", encoding="utf-8")
        from rag_universal.core import load_config

        config = load_config(root, None)
        query = "local CAS validation warns for core.update but misses canonical target.call entity_operation update with expected_source_revision and later conflict handler"
        variants = build_query_variants(query, config, "frontend")
        self.assertGreaterEqual(len(variants), 2)
        self.assertEqual(variants[0], query)
        self.assertLessEqual(len(variants), 3)
        self.assertTrue(any("target.call" in variant for variant in variants[1:]))
        self.assertTrue(any("expected_source_revision" in variant for variant in variants[1:]))
        signatures = {" ".join(sorted(set(tokenize(variant)))) for variant in variants}
        self.assertEqual(len(signatures), len(variants))

    def test_fuse_ranked_results_prefers_document_supported_by_multiple_variants(self) -> None:
        fused = fuse_ranked_results(
            [
                [
                    {"source": "src/A.php", "start_line": 1, "heading": "A", "score": 0.6},
                    {"source": "src/B.php", "start_line": 1, "heading": "B", "score": 0.9},
                ],
                [
                    {"source": "src/A.php", "start_line": 1, "heading": "A", "score": 0.55},
                ],
            ]
        )
        self.assertEqual(fused[0]["source"], "src/A.php")
        self.assertGreater(fused[0]["fusion_hits"], 1)

    def test_can_stop_variant_search_when_primary_top_is_reinforced(self) -> None:
        primary = [
            {"source": "src/A.php", "start_line": 1, "heading": "A", "score": 1.7},
            {"source": "src/B.php", "start_line": 1, "heading": "B", "score": 1.0},
        ]
        fused = [
            {"source": "src/A.php", "start_line": 1, "heading": "A", "score": 1.9, "fusion_hits": 2},
            {"source": "src/B.php", "start_line": 1, "heading": "B", "score": 1.2, "fusion_hits": 1},
        ]
        from rag_universal.core import can_stop_variant_search

        self.assertTrue(can_stop_variant_search(primary, fused, 1))

    def test_compute_bm25_scores_reuses_token_cache(self) -> None:
        root = self.make_project()
        build_index(root)
        from rag_universal.core import compute_bm25_scores, get_index_dir, load_config, load_search_cache

        config = load_config(root, None)
        connection = load_search_cache(get_index_dir(root, config))
        self.assertIsNotNone(connection)
        cache: dict[str, list[object]] = {}
        first = compute_bm25_scores(connection, Counter({"readme": 1, "strict": 1}), total_docs=3, avg_len=10.0, token_rows_cache=cache)
        self.assertTrue(cache)
        self.assertTrue(first)
        cache_keys = set(cache)
        second = compute_bm25_scores(connection, Counter({"strict": 1}), total_docs=3, avg_len=10.0, token_rows_cache=cache)
        self.assertEqual(cache_keys, set(cache))
        self.assertTrue(second)

    def test_cached_path_candidates_reuses_lookup_cache(self) -> None:
        root = self.make_project()
        build_index(root)
        from rag_universal.core import cached_path_candidates, get_index_dir, load_config, load_search_cache

        config = load_config(root, None)
        connection = load_search_cache(get_index_dir(root, config))
        self.assertIsNotNone(connection)
        cache: dict[tuple[str, ...], dict[int, float]] = {}
        first = cached_path_candidates(connection, ["README.md"], cache)
        self.assertTrue(first)
        self.assertEqual(len(cache), 1)
        second = cached_path_candidates(connection, ["README.md"], cache)
        self.assertEqual(first, second)
        self.assertEqual(len(cache), 1)

    def test_cached_lexicon_candidates_reuses_lookup_cache(self) -> None:
        root = self.make_project()
        build_index(root)
        from rag_universal.core import cached_lexicon_candidates, get_index_dir, load_config, load_search_cache, score_query_profile

        config = load_config(root, None)
        connection = load_search_cache(get_index_dir(root, config))
        self.assertIsNotNone(connection)
        profile = score_query_profile("StrictGuard", "implementation", None)
        cache: dict[tuple[str, tuple[str, ...]], dict[int, float]] = {}
        first = cached_lexicon_candidates(connection, "StrictGuard", profile, cache)
        self.assertTrue(first)
        self.assertEqual(len(cache), 1)
        second = cached_lexicon_candidates(connection, "StrictGuard", profile, cache)
        self.assertEqual(first, second)
        self.assertEqual(len(cache), 1)

    def test_status_and_mcp_dispatch(self) -> None:
        root = self.make_project()
        missing = index_status(root)
        self.assertFalse(missing["exists"])

        build_index(root)
        status = index_status(root)
        self.assertTrue(status["exists"])
        self.assertFalse(status["stale"])

        (root / "CHANGELOG.md").write_text("# Changelog\n\nNew indexed document.", encoding="utf-8")
        stale = index_status(root)
        self.assertTrue(stale["stale"])
        self.assertIn("source files changed", stale["reason"])
        build_index(root)
        self.assertFalse(index_status(root)["stale"])

        init = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"clientInfo": {"name": "DeepSeek Code", "version": "v4"}},
            },
            str(root),
            None,
        )
        self.assertEqual(init["result"]["serverInfo"]["name"], "rag-universal")

        listed = handle_message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, str(root), None)
        names = {tool["name"] for tool in listed["result"]["tools"]}
        self.assertEqual(
            {
                "rag_search",
                "rag_reindex",
                "rag_status",
                "rag_coverage",
                "rag_symbol",
                "rag_deps",
                "rag_quality_check",
                "rag_knowledge_build",
                "rag_knowledge_profile",
                "rag_knowledge_status",
            },
            names,
        )
        for tool in listed["result"]["tools"]:
            properties = tool["inputSchema"]["properties"]
            self.assertIn("root", properties)
            self.assertIn("config", properties)

        called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "rag_search", "arguments": {"query": "stop guard", "top_k": 1, "mode": "fdr"}},
            },
            str(root),
            None,
        )
        payload = json.loads(called["result"]["content"][0]["text"])
        self.assertEqual(payload[0]["source"], "README.md")
        self.assertEqual(payload[0]["fdr_role"], "docs")

        quality_called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "rag_quality_check",
                    "arguments": {"case_limit": 3, "top_k": 3, "auto_reindex": True, "include_cases": False, "min_cases": 3},
                },
            },
            str(root),
            None,
        )
        quality_payload = json.loads(quality_called["result"]["content"][0]["text"])
        self.assertEqual(quality_payload["schema_version"], "rag.quality-check.v1")
        self.assertEqual(quality_payload["health"]["baseline"], "keyword")
        self.assertIn("delta", quality_payload["summary"])

    def test_mcp_tool_calls_can_override_server_root_per_call(self) -> None:
        server_root = self.make_project()
        target_root = self.make_project()
        (target_root / "README.md").write_text(
            "# Target\n\nMCP per-call root override beta token lives here.",
            encoding="utf-8",
        )
        build_index(server_root)
        build_index(target_root)

        status_called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {"name": "rag_status", "arguments": {"root": str(target_root)}},
            },
            str(server_root),
            None,
        )
        status_payload = json.loads(status_called["result"]["content"][0]["text"])
        self.assertEqual(status_payload["manifest"]["project_root"], str(target_root.resolve()))
        self.assertTrue(status_payload["index_dir"].startswith(str(target_root.resolve())))

        search_called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {
                    "name": "rag_search",
                    "arguments": {"root": str(target_root), "query": "per-call root override beta token", "top_k": 1},
                },
            },
            str(server_root),
            None,
        )
        search_payload = json.loads(search_called["result"]["content"][0]["text"])
        self.assertEqual(search_payload[0]["source"], "README.md")
        self.assertIn("beta token", search_payload[0]["preview"])

    def test_mcp_hardened_mode_requires_absolute_root_for_project_tools(self) -> None:
        root = self.make_project()
        config_path = root / ".mcp" / "rag-server" / "rag.config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            json.dumps({"schema_version": "rag.config.v1", "mcp": {"require_explicit_root": True}}),
            encoding="utf-8",
        )
        build_index(root)

        listed = handle_message({"jsonrpc": "2.0", "id": 7, "method": "tools/list"}, str(root), None)
        schemas = {tool["name"]: tool["inputSchema"] for tool in listed["result"]["tools"]}
        self.assertIn("root", schemas["rag_search"]["required"])
        self.assertNotIn("required", schemas["rag_status"])

        missing_root = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 8,
                "method": "tools/call",
                "params": {"name": "rag_search", "arguments": {"query": "stop guard", "top_k": 1}},
            },
            str(root),
            None,
        )
        self.assertIn("error", missing_root)
        self.assertIn("explicit root required", missing_root["error"]["message"])

        relative_root = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 9,
                "method": "tools/call",
                "params": {"name": "rag_search", "arguments": {"root": ".", "query": "stop guard", "top_k": 1}},
            },
            str(root),
            None,
        )
        self.assertIn("error", relative_root)
        self.assertIn("absolute path", relative_root["error"]["message"])

        status_called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/call",
                "params": {"name": "rag_status", "arguments": {}},
            },
            str(root),
            None,
        )
        status_payload = json.loads(status_called["result"]["content"][0]["text"])
        self.assertEqual(status_payload["mcp_server"]["server_root"], str(root.resolve()))
        self.assertEqual(status_payload["mcp_server"]["effective_root"], str(root.resolve()))
        self.assertFalse(status_payload["mcp_server"]["explicit_root"])
        self.assertTrue(status_payload["mcp_server"]["require_explicit_root"])
        self.assertTrue(status_payload["mcp_server"]["stale_namespace_risk"])

        absolute_root = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "tools/call",
                "params": {"name": "rag_search", "arguments": {"root": str(root.resolve()), "query": "stop guard", "top_k": 1}},
            },
            str(root),
            None,
        )
        payload = json.loads(absolute_root["result"]["content"][0]["text"])
        self.assertEqual(payload[0]["source"], "README.md")

    def test_mcp_search_auto_reindex_defaults_to_configured_true(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "README.md").write_text("# Demo\n\nMCP default refresh token appears here.", encoding="utf-8")

        called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {
                    "name": "rag_search",
                    "arguments": {"query": "MCP default refresh token", "top_k": 1, "with_plan": True},
                },
            },
            str(root),
            None,
        )
        payload = json.loads(called["result"]["content"][0]["text"])
        self.assertTrue(payload["diagnostics"]["index_stale_before_search"])
        self.assertTrue(payload["diagnostics"]["index_reindexed"])
        self.assertFalse(payload["diagnostics"]["index_stale_after_search"])
        self.assertEqual(payload["results"][0]["source"], "README.md")
        self.assertEqual(index_status(root)["manifest"]["build_mode"], "incremental")

    def test_mcp_auto_reindex_default_can_be_configured_or_overridden(self) -> None:
        root = self.make_project()
        config_path = root / ".mcp" / "rag-server" / "rag.config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            json.dumps({"schema_version": "rag.config.v1", "mcp": {"auto_reindex_default": False}}),
            encoding="utf-8",
        )

        schema = next(tool for tool in tool_definitions() if tool["name"] == "rag_search")["inputSchema"]
        self.assertNotIn("default", schema["properties"]["auto_reindex"])
        self.assertTrue(mcp_auto_reindex_default({"mcp": {"auto_reindex_default": True}}))
        self.assertFalse(mcp_auto_reindex_default({"mcp": {"auto_reindex_default": False}}))
        self.assertTrue(mcp_require_explicit_root_default({"mcp": {"require_explicit_root": True}}))
        self.assertFalse(mcp_require_explicit_root_default({"mcp": {"require_explicit_root": False}}))
        self.assertFalse(resolve_mcp_auto_reindex({}, str(root), None))
        self.assertTrue(resolve_mcp_auto_reindex({"auto_reindex": True}, str(root), None))
        self.assertFalse(resolve_mcp_auto_reindex({"auto_reindex": False}, str(root), None))
        self.assertFalse(resolve_mcp_require_explicit_root(str(root), None))
        self.assertTrue(resolve_mcp_require_explicit_root(str(root), None, override=True))
        self.assertFalse(cli_auto_reindex_default({"cli": {"auto_reindex_default": False}}))
        self.assertTrue(cli_auto_reindex_default({"cli": {"auto_reindex_default": True}}))
        self.assertFalse(resolve_cli_auto_reindex(None, str(root), None))
        self.assertTrue(resolve_cli_auto_reindex(True, str(root), None))
        self.assertFalse(resolve_cli_auto_reindex(False, str(root), None))

    def test_mcp_memory_cache_storage_uses_in_memory_sqlite_replica(self) -> None:
        root = self.make_project()
        build_index(root)
        index_dir = get_index_dir(root, load_config(root, None))
        try:
            configure_search_cache_storage("memory")
            memory_connection = load_search_cache(index_dir)
            self.assertIsNotNone(memory_connection)
            memory_databases = [tuple(row) for row in memory_connection.execute("PRAGMA database_list").fetchall()]
            self.assertEqual(memory_databases[0][2], "")
            self.assertEqual(search_cache_storage_mode(), "memory")
            results = search_index(root, None, "strict stop guard", top_k=1)
            self.assertEqual(results[0]["source"], "README.md")

            configure_search_cache_storage("disk")
            disk_connection = load_search_cache(index_dir)
            self.assertIsNotNone(disk_connection)
            disk_databases = [tuple(row) for row in disk_connection.execute("PRAGMA database_list").fetchall()]
            self.assertTrue(disk_databases[0][2].endswith("search.sqlite"))
            self.assertEqual(search_cache_storage_mode(), "disk")
        finally:
            configure_search_cache_storage("disk")
            close_search_cache_connections(index_dir)

    def test_auto_reindex_and_watch_refresh_changed_sources(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "README.md").write_text("# Demo\n\nFresh realtime token appears here.", encoding="utf-8")

        stale = ensure_fresh_index(root, None, False)
        self.assertTrue(stale["stale_before"])
        self.assertFalse(stale["reindexed"])
        results_without_reindex = search_index(root, None, "fresh realtime token", top_k=1)
        self.assertEqual(results_without_reindex, [])

        payload = search_index_with_plan(root, None, "fresh realtime token", top_k=1, auto_reindex=True)
        self.assertTrue(payload["diagnostics"]["index_stale_before_search"])
        self.assertTrue(payload["diagnostics"]["index_reindexed"])
        self.assertFalse(payload["diagnostics"]["index_stale_after_search"])
        self.assertEqual(payload["results"][0]["source"], "README.md")

        (root / "CHANGELOG.md").write_text("# Changelog\n\nWatched refresh token.", encoding="utf-8")
        watched = watch_index(root, None, interval_seconds=0, debounce_seconds=0, max_cycles=1)
        self.assertEqual(watched["rebuilds"], 1)
        self.assertFalse(watched["status"]["stale"])
        self.assertEqual(search_index(root, None, "watched refresh token", top_k=1)[0]["source"], "CHANGELOG.md")
        self.assertEqual(watched["status"]["manifest"]["build_mode"], "incremental")

    def test_freshness_cache_is_scoped_by_config_hash(self) -> None:
        root = self.make_project()
        (root / "config-a.json").write_text(json.dumps({"schema_version": "rag.config.v1"}), encoding="utf-8")
        (root / "config-b.json").write_text(
            json.dumps({"schema_version": "rag.config.v1", "search": {"min_score": 0.01}}),
            encoding="utf-8",
        )
        build_index(root, "config-a.json")

        first = ensure_fresh_index(root, "config-a.json", False)
        self.assertFalse(first["stale_before"])
        second = ensure_fresh_index(root, "config-b.json", False)
        self.assertTrue(second["stale_before"])
        self.assertIn("config hash changed", second["reason_before"])

    def test_search_auto_reindex_skips_source_changes_outside_focus_paths(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "src" / "service.py").write_text(
            "import json\n\nclass StrictGuard:\n    def unrelated_worker(self):\n        return 'changed elsewhere'\n",
            encoding="utf-8",
        )

        payload = search_index_with_plan(root, None, "README.md strict stop guard", top_k=1, auto_reindex=True)

        diagnostics = payload["diagnostics"]
        self.assertTrue(diagnostics["index_stale_before_search"])
        self.assertFalse(diagnostics["index_reindexed"])
        self.assertTrue(diagnostics["auto_reindex_skipped"])
        self.assertEqual(diagnostics["auto_reindex_skip_reason"], "source changes outside focus_paths")
        self.assertEqual(diagnostics["auto_reindex_focus_paths"], ["README.md"])
        self.assertEqual(diagnostics["source_delta"]["changed_sources"], ["src/service.py"])
        self.assertTrue(diagnostics["index_stale_after_search"])
        self.assertEqual(payload["results"][0]["source"], "README.md")

    def test_search_auto_reindex_uses_grace_window_for_broad_source_changes(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "README.md").write_text("# Demo\n\nFirst grace refresh token.", encoding="utf-8")
        refreshed = search_index_with_plan(root, None, "First grace refresh token", top_k=1, auto_reindex=True)
        self.assertTrue(refreshed["diagnostics"]["index_reindexed"])

        (root / "CHANGELOG.md").write_text("# Changelog\n\nConcurrent agent changed another source.", encoding="utf-8")
        skipped = search_index_with_plan(root, None, "strict stop guard", top_k=1, auto_reindex=True)

        diagnostics = skipped["diagnostics"]
        self.assertTrue(diagnostics["index_stale_before_search"])
        self.assertFalse(diagnostics["index_reindexed"])
        self.assertTrue(diagnostics["auto_reindex_skipped"])
        self.assertEqual(diagnostics["auto_reindex_skip_reason"], "source changes inside auto-reindex grace window")
        self.assertEqual(diagnostics["source_delta"]["changed_sources"], ["CHANGELOG.md"])
        self.assertTrue(diagnostics["index_stale_after_search"])

    def test_search_auto_reindex_refreshes_changed_focus_even_inside_grace_window(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "README.md").write_text("# Demo\n\nInitial grace state token.", encoding="utf-8")
        refreshed = search_index_with_plan(root, None, "Initial grace state token", top_k=1, auto_reindex=True)
        self.assertTrue(refreshed["diagnostics"]["index_reindexed"])

        (root / "README.md").write_text("# Demo\n\nFocused change must refresh.", encoding="utf-8")
        focused = search_index_with_plan(root, None, "README.md Focused change must refresh", top_k=1, auto_reindex=True)

        self.assertTrue(focused["diagnostics"]["index_stale_before_search"])
        self.assertTrue(focused["diagnostics"]["index_reindexed"])
        self.assertFalse(focused["diagnostics"]["auto_reindex_skipped"])
        self.assertFalse(focused["diagnostics"]["index_stale_after_search"])
        self.assertEqual(focused["results"][0]["source"], "README.md")

    def test_incremental_index_updates_changed_added_and_deleted_sources(self) -> None:
        root = self.make_project()
        build_index(root)
        (root / "README.md").write_text("# Demo\n\nIncremental refresh token.", encoding="utf-8")
        (root / "CHANGELOG.md").write_text("# Changelog\n\nIncremental add token.", encoding="utf-8")
        (root / "schemas" / "demo.schema.json").unlink()

        manifest = build_index(root, None, incremental=True)
        self.assertEqual(manifest["build_mode"], "incremental")
        self.assertEqual(manifest["change_summary"]["changed_sources"], 2)
        self.assertEqual(manifest["change_summary"]["deleted_sources"], 1)

        results = search_index(root, None, "incremental refresh token", top_k=1)
        self.assertEqual(results[0]["source"], "README.md")
        added = search_index(root, None, "incremental add token", top_k=1)
        self.assertEqual(added[0]["source"], "CHANGELOG.md")
        coverage = index_coverage(root, None, ["schemas/demo.schema.json"])
        self.assertFalse(coverage["paths"][0]["indexed"])
        self.assertEqual(coverage["paths"][0]["reason"], "missing")

    def test_cli_accepts_root_after_subcommand(self) -> None:
        root = self.make_project()
        tool = ROOT / "tools" / "rag.py"
        index = subprocess.run(
            [sys.executable, str(tool), "index", "--root", str(root)],
            check=True,
            text=True,
            capture_output=True,
        )
        manifest = json.loads(index.stdout)
        self.assertEqual(manifest["num_files"], 6)

        search = subprocess.run(
            [sys.executable, str(tool), "search", "--root", str(root), "strict stop guard", "--top-k", "1"],
            check=True,
            text=True,
            capture_output=True,
        )
        results = json.loads(search.stdout)
        self.assertEqual(results[0]["source"], "README.md")

        with mock.patch("rag_universal.core.load_chunks", side_effect=AssertionError("search cache was bypassed")):
            cached_results = search_index(root, None, "strict stop guard", top_k=1)
        self.assertEqual(cached_results[0]["source"], "README.md")

    def test_cli_auto_reindex_default_uses_project_config_and_can_be_disabled(self) -> None:
        root = self.make_project()
        tool = ROOT / "tools" / "rag.py"
        config_path = root / ".mcp" / "rag-server" / "rag.config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            json.dumps({"schema_version": "rag.config.v1", "cli": {"auto_reindex_default": True}}),
            encoding="utf-8",
        )
        subprocess.run([sys.executable, str(tool), "index", "--root", str(root)], check=True, text=True, capture_output=True)

        (root / "README.md").write_text("# Demo\n\nCLI configured refresh token appears here.", encoding="utf-8")
        refreshed = subprocess.run(
            [sys.executable, str(tool), "search", "--root", str(root), "CLI configured refresh token", "--top-k", "1", "--with-plan"],
            check=True,
            text=True,
            capture_output=True,
        )
        refreshed_payload = json.loads(refreshed.stdout)
        self.assertTrue(refreshed_payload["diagnostics"]["index_reindexed"])
        self.assertEqual(refreshed_payload["results"][0]["source"], "README.md")

        (root / "README.md").write_text("# Demo\n\nZirconium qxnoauto sentinel appears here.", encoding="utf-8")
        not_refreshed = subprocess.run(
            [
                sys.executable,
                str(tool),
                "search",
                "--root",
                str(root),
                "zirconium qxnoauto sentinel",
                "--top-k",
                "1",
                "--with-plan",
                "--no-auto-reindex",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        not_refreshed_payload = json.loads(not_refreshed.stdout)
        self.assertTrue(not_refreshed_payload["diagnostics"]["index_stale_before_search"])
        self.assertFalse(not_refreshed_payload["diagnostics"]["index_reindexed"])
        self.assertEqual(not_refreshed_payload["results"], [])

    def test_cli_config_can_be_relative_to_current_directory(self) -> None:
        root = self.make_project()
        tool = ROOT / "tools" / "rag.py"
        index = subprocess.run(
            [sys.executable, str(tool), "index", "--root", str(root), "--config", "rag.config.example.json"],
            cwd=str(ROOT),
            check=True,
            text=True,
            capture_output=True,
        )
        manifest = json.loads(index.stdout)
        self.assertEqual(manifest["num_files"], 6)
        self.assertTrue(manifest["config_source"]["explicit"])
        self.assertTrue(manifest["config_source"]["path"].endswith("rag.config.example.json"))

    def test_explicit_missing_config_fails_closed(self) -> None:
        root = self.make_project()
        tool = ROOT / "tools" / "rag.py"
        missing_config = ".mcp/rag-server/rag.config.json"

        with self.assertRaises(FileNotFoundError):
            load_config(root, missing_config)

        failed = subprocess.run(
            [sys.executable, str(tool), "status", "--root", str(root), "--config", missing_config],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("rag config not found", failed.stderr)

    def test_project_local_config_does_not_fallback_to_process_cwd(self) -> None:
        server_root = self.make_project()
        target_root = self.make_project()
        config_rel = ".mcp/rag-server/rag.config.json"
        (server_root / ".mcp" / "rag-server").mkdir(parents=True)
        (server_root / config_rel).write_text(json.dumps({"schema_version": "rag.config.v1"}), encoding="utf-8")

        with mock.patch("rag_universal.core.Path.cwd", return_value=server_root):
            with self.assertRaises(FileNotFoundError):
                load_config(target_root, config_rel)

    def test_default_config_can_live_under_local_rag_server_directory(self) -> None:
        root = self.make_project()
        (root / ".mcp" / "rag-server").mkdir(parents=True)
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "tests" / "Unit" / "BuildAndPushNodeImagesScriptTest.php").write_text("<?php\n", encoding="utf-8")
        (root / ".mcp" / "rag-server" / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "exclude_dirs": ["tests", "node_modules"],
                    "force_include_globs": ["tests/Unit/*ScriptTest.php"],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        coverage = index_coverage(root, None, ["tests/Unit/BuildAndPushNodeImagesScriptTest.php"])
        self.assertTrue(coverage["paths"][0]["indexed"])

    def test_mcp_per_call_root_resolves_server_config_relative_to_effective_root(self) -> None:
        server_root = self.make_project()
        target_root = self.make_project()
        config_rel = ".mcp/rag-server/rag.config.json"
        for root in (server_root, target_root):
            (root / ".mcp" / "rag-server").mkdir(parents=True)
        (server_root / config_rel).write_text(
            json.dumps({"schema_version": "rag.config.v1", "include_globs": ["server.only"]}),
            encoding="utf-8",
        )
        (server_root / "server.only").write_text("server config token", encoding="utf-8")
        (target_root / config_rel).write_text(
            json.dumps({"schema_version": "rag.config.v1", "include_globs": ["target.only"]}),
            encoding="utf-8",
        )
        (target_root / "target.only").write_text("target config token", encoding="utf-8")
        build_index(server_root, config_rel)
        build_index(target_root, config_rel)

        called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 12,
                "method": "tools/call",
                "params": {
                    "name": "rag_search",
                    "arguments": {"root": str(target_root.resolve()), "query": "target config token", "top_k": 1},
                },
            },
            str(server_root),
            config_rel,
        )
        payload = json.loads(called["result"]["content"][0]["text"])
        self.assertEqual(payload[0]["source"], "target.only")

        status_called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 13,
                "method": "tools/call",
                "params": {"name": "rag_status", "arguments": {"root": str(target_root.resolve())}},
            },
            str(server_root),
            config_rel,
        )
        status_payload = json.loads(status_called["result"]["content"][0]["text"])
        self.assertEqual(status_payload["mcp_server"]["effective_config"], config_rel)
        self.assertEqual(status_payload["mcp_server"]["effective_config_path"], str((target_root / config_rel).resolve()))

    def test_deploy_to_project_wires_explicit_project_local_config(self) -> None:
        if shutil.which("rsync") is None:
            self.skipTest("rsync is required by deploy-to-project.sh")
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        target = Path(temp.name) / "project"
        target.mkdir()
        deploy = ROOT / "tools" / "deploy-to-project.sh"

        subprocess.run([str(deploy), str(target), "--no-index"], check=True, text=True, capture_output=True)

        config_path = target / ".mcp" / "rag-server" / "rag.config.json"
        self.assertTrue(config_path.exists())
        mcp_config = json.loads((target / ".mcp.json").read_text(encoding="utf-8"))
        args = mcp_config["mcpServers"]["rag"]["args"]
        self.assertEqual(args[0], ".mcp/rag-server/tools/rag.py")
        self.assertIn("--config", args)
        self.assertEqual(args[args.index("--config") + 1], ".mcp/rag-server/rag.config.json")

    def test_force_include_contract_tests_and_coverage_report(self) -> None:
        root = self.make_project()
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "tests" / "Unit" / "BuildAndPushNodeImagesScriptTest.php").write_text("<?php\n", encoding="utf-8")
        (root / "tests" / "Unit" / "RegularTest.php").write_text("<?php\n", encoding="utf-8")
        outside = root.parent / "outside.txt"
        outside.write_text("outside root", encoding="utf-8")
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "exclude_dirs": ["tests", "node_modules"],
                    "force_include_globs": ["tests/Unit/*ScriptTest.php"],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        coverage = index_coverage(
            root,
            None,
            [
                "tests/Unit/BuildAndPushNodeImagesScriptTest.php",
                "tests/Unit/RegularTest.php",
                "Dockerfile",
                ".dockerignore",
                "../outside.txt",
                str(outside),
            ],
        )
        by_source = {entry["source"]: entry for entry in coverage["paths"]}
        self.assertTrue(by_source["tests/Unit/BuildAndPushNodeImagesScriptTest.php"]["indexed"])
        self.assertTrue(by_source["tests/Unit/BuildAndPushNodeImagesScriptTest.php"]["force_included"])
        self.assertFalse(by_source["tests/Unit/RegularTest.php"]["indexed"])
        self.assertEqual(by_source["tests/Unit/RegularTest.php"]["reason"], "excluded_dir")
        self.assertTrue(by_source["Dockerfile"]["indexed"])
        self.assertTrue(by_source[".dockerignore"]["indexed"])
        self.assertEqual(coverage["paths"][4]["reason"], "outside_root")
        self.assertFalse(coverage["paths"][4]["exists"])
        self.assertEqual(coverage["paths"][5]["reason"], "outside_root")
        self.assertFalse(coverage["paths"][5]["exists"])

    def test_default_force_include_indexes_review_test_evidence(self) -> None:
        root = self.make_project()
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "tests" / "Unit" / "_tmp_storage").mkdir(parents=True)
        (root / "uier" / "tests" / "Feature").mkdir(parents=True)
        (root / "uier" / "public" / "js").mkdir(parents=True)
        (root / "uier-spa" / "src" / "tests").mkdir(parents=True)
        (root / "storage" / "payload" / "work_items").mkdir(parents=True)
        (root / "tests" / "Unit" / "YamlHelperTest.php").write_text("<?php\n", encoding="utf-8")
        (root / "tests" / "Unit" / "_tmp_storage" / "payload.json").write_text('{"runtime":true}', encoding="utf-8")
        (root / "uier" / "tests" / "Feature" / "DashboardTest.php").write_text("<?php\n", encoding="utf-8")
        (root / "uier" / "public" / "js" / "app.js").write_text("initFormSubmit()\n", encoding="utf-8")
        (root / "uier-spa" / "src" / "tests" / "SettingsView.test.ts").write_text("test('x', () => {})\n", encoding="utf-8")
        (root / "storage" / "payload" / "work_items" / "payload.json").write_text('{"runtime":true}', encoding="utf-8")
        (root / "rag.config.json").write_text(
            json.dumps({"schema_version": "rag.config.v1", "exclude_dirs": ["tests", "public", "storage", "_tmp_storage"]}),
            encoding="utf-8",
        )
        build_index(root)
        coverage = index_coverage(
            root,
            None,
            [
                "tests/Unit/YamlHelperTest.php",
                "uier/tests/Feature/DashboardTest.php",
                "uier/public/js/app.js",
                "uier-spa/src/tests/SettingsView.test.ts",
            ],
        )
        self.assertEqual(coverage["summary"]["indexed"], 4)
        sources = {chunk["source"] for chunk in load_chunks(root / ".rag-index")}
        self.assertNotIn("tests/Unit/_tmp_storage/payload.json", sources)
        self.assertNotIn("storage/payload/work_items/payload.json", sources)

    def test_project_config_can_force_include_local_rag_server_under_dot_mcp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".mcp" / "rag-server" / "rag_universal").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "tests").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "README.md").write_text(
            "# Local RAG\n\nBM25 ranking and token-aware read plan.",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "rag_universal" / "core.py").write_text(
            "def score_rag():\n    return 'bm25 vector ranking'\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "tests" / "test_rag_universal.py").write_text(
            "def test_read_plan():\n    assert True\n",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "force_include_globs": [
                        ".mcp/rag-server/*.md",
                        ".mcp/rag-server/rag_universal/*.py",
                        ".mcp/rag-server/tests/*.py",
                        ".mcp/rag-server/**/*.md",
                        ".mcp/rag-server/**/*.py",
                    ],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        coverage = index_coverage(
            root,
            None,
            [
                ".mcp/rag-server/README.md",
                ".mcp/rag-server/rag_universal/core.py",
            ],
        )
        self.assertEqual(coverage["summary"]["indexed"], 2)
        results = search_index(root, None, "rag ranking bm25 read plan", top_k=2, mode="implementation")
        self.assertTrue(results[0]["source"].startswith(".mcp/rag-server/"))

    def test_path_query_suffix_escapes_like_wildcards(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "docs" / "sub").mkdir(parents=True)
        (root / "docs" / "sub" / "foo_bar.md").write_text("# Exact\n\nPath exact.", encoding="utf-8")
        (root / "docs" / "sub" / "fooXbar.md").write_text("# Wrong\n\nPath wrong.", encoding="utf-8")
        build_index(root)
        results = search_index(root, None, "sub/foo_bar.md", top_k=2)
        self.assertEqual(results[0]["source"], "docs/sub/foo_bar.md")
        by_source = {item["source"]: item for item in results}
        self.assertEqual(by_source["docs/sub/foo_bar.md"]["path_match"], 0.85)
        self.assertEqual(by_source.get("docs/sub/fooXbar.md", {}).get("path_match", 0.0), 0.0)

    def test_explicit_path_priority_prefers_cited_file(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs").mkdir()
        (root / "Docs" / "general.md").write_text(
            "# General\n\nDockerfile strict stop guard strict stop guard strict stop guard.",
            encoding="utf-8",
        )
        (root / "Dockerfile").write_text("FROM scratch\n# strict guard image\n", encoding="utf-8")
        build_index(root)
        results = search_index(root, None, "review evidence for Dockerfile strict stop guard", top_k=2)
        self.assertEqual(results[0]["source"], "Dockerfile")
        self.assertEqual(results[0]["path_match"], 1.0)

    def test_explicit_path_fast_path_returns_multiple_cited_files(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs").mkdir()
        (root / "Docs" / "general.md").write_text(
            "# General\n\nstrict stop guard " * 200,
            encoding="utf-8",
        )
        (root / "src").mkdir()
        (root / "src" / "one.py").write_text("def one(): pass\n", encoding="utf-8")
        (root / "src" / "two.py").write_text("def two(): pass\n", encoding="utf-8")
        build_index(root)
        results = search_index(
            root,
            None,
            "review evidence Cited files: src/one.py, src/two.py. " + ("strict stop guard " * 200),
            top_k=2,
        )
        self.assertEqual([item["source"] for item in results], ["src/one.py", "src/two.py"])

    def test_query_term_trimming_keeps_high_signal_terms(self) -> None:
        counts = token_counts("the and " + " ".join(f"term{i}" for i in range(40)) + " Dockerfile Dockerfile")
        trimmed = trim_query_counts(
            counts,
            {"search": {"max_query_terms": 16, "query_stopwords": ["the", "and"]}},
        )
        self.assertLessEqual(len(trimmed), 16)
        self.assertNotIn("the", trimmed)
        self.assertIn("Dockerfile".lower(), trimmed)

    def test_search_penalizes_snapshot_noise(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "plugins" / "demo" / ".snapshots" / "1.0.0" / "seeds").mkdir(parents=True)
        (root / "plugins" / "demo" / ".snapshots" / "1.0.0" / "seeds" / "demo.yaml").write_text(
            "env: storage\nsecret: dist\nbuild_context: true\n",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps({"schema_version": "rag.config.v1", "search": {"min_score": 0.0}}),
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "env storage dist secret build context", top_k=1, filter_source=".snapshots")
        self.assertEqual(results[0]["source"], "plugins/demo/.snapshots/1.0.0/seeds/demo.yaml")
        self.assertLess(results[0]["source_penalty"], 1.0)

    def test_fdr_mode_returns_role_diverse_evidence_bundle(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs" / "plans").mkdir(parents=True)
        (root / "Docs" / "plans" / "rollout-plan.md").write_text(
            "# Rollout migration plan\n\nRollout migration dry-run contract.",
            encoding="utf-8",
        )
        (root / "src").mkdir()
        (root / "src" / "rollout.py").write_text(
            "def rollout_migration():\n    return 'dry-run contract'\n",
            encoding="utf-8",
        )
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "tests" / "Unit" / "RolloutContractTest.php").write_text(
            "<?php\n// rollout migration dry-run contract test\n",
            encoding="utf-8",
        )
        (root / "Dockerfile").write_text(
            "FROM scratch\n# rollout migration dry-run contract image\n",
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "rollout migration dry-run contract", top_k=4, mode="fdr")
        roles = {result["fdr_role"] for result in results}
        self.assertEqual(len(results), 4)
        self.assertIn("plan", roles)
        self.assertIn("implementation", roles)
        self.assertIn("test", roles)
        self.assertIn("build_file", roles)

    def test_architecture_mode_prefers_canonical_sections_and_deprioritizes_superseded(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs" / "visual").mkdir(parents=True)
        (root / "Docs" / "visual" / "master-spec.md").write_text(
            "# Visual Studio Master\n\nStatus: Canonical / master\n\n## Owner Boundary\n\nVisual Studio reuses automation-core owner boundaries.",
            encoding="utf-8",
        )
        (root / "Docs" / "visual" / "old-report.md").write_text(
            "# Old Report\n\nStatus: SUPERSEDED\n\nSTOP - DO NOT IMPLEMENT FROM THIS REPORT.\n\nVisual Studio automation-core owner boundaries.",
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "Visual Studio automation-core owner boundaries", top_k=2, mode="architecture")
        self.assertEqual(results[0]["source"], "Docs/visual/master-spec.md")
        self.assertEqual(results[0]["document_status"], "canonical")
        by_source = {item["source"]: item for item in results}
        self.assertEqual(by_source["Docs/visual/old-report.md"]["document_status"], "superseded")
        self.assertLess(by_source["Docs/visual/old-report.md"]["status_boost"], 1.0)

    def test_search_with_plan_returns_section_hints_and_budget_guard(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs").mkdir()
        (root / "Docs" / "spec.md").write_text(
            "# Product Spec\n\nStatus: Canonical / master\n\n## Provider Runtime\n\nProvider runtime facade contract.",
            encoding="utf-8",
        )
        build_index(root)
        payload = search_index_with_plan(root, None, "provider runtime facade contract", top_k=3, mode="architecture")
        self.assertIn("results", payload)
        self.assertIn("read_plan", payload)
        self.assertEqual(payload["read_plan"]["mode"], "architecture")
        self.assertIn("Read only", payload["read_plan"]["budget_hint"])
        self.assertEqual(payload["read_plan"]["items"][0]["source"], "Docs/spec.md")
        self.assertIn("Provider Runtime", payload["read_plan"]["items"][0]["read_hint"])
        empty = search_index_with_plan(root, None, "zzzzqqq src/Absent.php", top_k=3, mode="default")
        self.assertTrue(empty["diagnostics"]["no_results"])
        self.assertEqual(empty["diagnostics"]["explicit_paths"], ["src/Absent.php"])
        self.assertTrue(empty["diagnostics"]["next_steps"])

    def test_read_plan_high_confidence_limits_to_single_section(self) -> None:
        results = [
            {
                "source": "app/Service.php",
                "read_hint": "app/Service.php:10",
                "fdr_role": "implementation",
                "section": "Service",
                "document_status": "normal",
                "score": 1.8,
                "start_line": 10,
                "heading": "Service",
            },
            {
                "source": "Docs/spec.md",
                "read_hint": "Docs/spec.md:1",
                "fdr_role": "docs",
                "section": "Spec",
                "document_status": "normal",
                "score": 0.6,
                "start_line": 1,
                "heading": "Spec",
            },
        ]
        plan = build_read_plan(results, mode="implementation")
        self.assertEqual(plan["confidence"]["level"], "high")
        self.assertEqual(len(plan["items"]), 1)
        self.assertEqual(plan["items"][0]["source"], "app/Service.php")

    def test_read_plan_low_confidence_keeps_multiple_sections(self) -> None:
        results = [
            {
                "source": "app/A.php",
                "read_hint": "app/A.php:10",
                "fdr_role": "implementation",
                "section": "A",
                "document_status": "normal",
                "score": 0.74,
                "start_line": 10,
                "heading": "A",
            },
            {
                "source": "app/B.php",
                "read_hint": "app/B.php:11",
                "fdr_role": "implementation",
                "section": "B",
                "document_status": "normal",
                "score": 0.68,
                "start_line": 11,
                "heading": "B",
            },
        ]
        plan = build_read_plan(results, mode="implementation")
        self.assertIn(plan["confidence"]["level"], {"low", "medium"})
        self.assertGreaterEqual(len(plan["items"]), 2)

    def test_split_large_text_tracks_chunk_start_lines(self) -> None:
        config = {"chunk": {"max_chars": 40, "min_chars": 1, "overlap_chars": 0}}
        text = "alpha line\nbeta line\n\nthird block starts here\nand continues"
        chunks = split_large_text(text, "uier-spa/src/api/example.ts", "example.ts", 10, config)
        self.assertGreaterEqual(len(chunks), 2)
        self.assertEqual(chunks[0]["start_line"], 10)
        self.assertEqual(chunks[1]["start_line"], 13)

    def test_read_hint_with_role_and_chunk_role(self) -> None:
        self.assertEqual(
            read_hint_with_role("uier-spa/src/api/visual-studio-assistant.ts", 14, "visual-studio-assistant.ts", "api_client"),
            "uier-spa/src/api/visual-studio-assistant.ts:14 [api client]",
        )
        self.assertEqual(
            chunk_role("app/Domain/Plugins/Workflows/WorkflowTargetCallExecutor.php", "WorkflowTargetCallExecutor.php", "<?php\nfinal class WorkflowTargetCallExecutor {}\n"),
            "workflow",
        )

    def test_frontend_high_confidence_results_drop_self_rag_and_test_noise(self) -> None:
        profile = {
            "mode": "frontend",
            "review_comment": True,
            "query_terms": {"target", "call", "expected_source_revision"},
            "review_terms": ["target.call", "expected_source_revision"],
        }
        results = [
            {
                "source": "uier-spa/src/api/visual-studio-assistant.ts",
                "fdr_role": "implementation",
                "score": 2.6,
                "start_line": 1,
                "heading": "visual-studio-assistant.ts",
            },
            {
                "source": ".mcp/rag-server/rag_universal/core.py",
                "fdr_role": "implementation",
                "score": 1.1,
                "start_line": 1,
                "heading": "core.py",
            },
            {
                "source": "uier-spa/src/features/data-tables-3/stores/viewport.test.ts",
                "fdr_role": "implementation",
                "score": 1.0,
                "start_line": 1,
                "heading": "viewport.test.ts",
            },
            {
                "source": "app/Domain/Plugins/Workflows/WorkflowTargetCallExecutor.php",
                "fdr_role": "implementation",
                "score": 0.9,
                "start_line": 1,
                "heading": "WorkflowTargetCallExecutor.php",
            },
        ]
        selected = select_search_results(results, 5, 1, "frontend", profile=profile)
        self.assertEqual(selected[0]["source"], "uier-spa/src/api/visual-studio-assistant.ts")
        self.assertNotIn(".mcp/rag-server/rag_universal/core.py", [item["source"] for item in selected])
        self.assertNotIn("uier-spa/src/features/data-tables-3/stores/viewport.test.ts", [item["source"] for item in selected])
        self.assertIn("app/Domain/Plugins/Workflows/WorkflowTargetCallExecutor.php", [item["source"] for item in selected])

    def test_query_role_bias_multiplier_prefers_matching_chunk_roles(self) -> None:
        profile = {
            "mode": "frontend",
            "query_terms": {"target", "call", "expected_source_revision"},
            "review_terms": ["target.call", "expected_source_revision"],
        }
        self.assertGreater(query_role_bias_multiplier("api_client", profile), 1.0)
        self.assertGreater(query_role_bias_multiplier("workflow", profile), 1.0)
        self.assertEqual(query_role_bias_multiplier("docs", profile), 1.0)

    def test_read_plan_role_rank_prefers_frontend_api_client_for_target_call(self) -> None:
        profile = {
            "mode": "frontend",
            "query_terms": {"target", "call", "expected_source_revision"},
            "review_terms": ["target.call", "expected_source_revision"],
        }
        self.assertLess(
            read_plan_role_rank({"chunk_role": "api_client"}, profile),
            read_plan_role_rank({"chunk_role": "workflow"}, profile),
        )

    def test_build_read_plan_prefers_repository_for_backend_audit_intent(self) -> None:
        results = [
            {
                "source": "app/Http/Controllers/DemoController.php",
                "read_hint": "app/Http/Controllers/DemoController.php:1 [controller]",
                "fdr_role": "implementation",
                "chunk_role": "controller",
                "section": "DemoController.php",
                "document_status": "normal",
                "score": 0.55,
                "start_line": 1,
                "heading": "DemoController.php",
            },
            {
                "source": "app/Domain/Demo/Repositories/DemoRepository.php",
                "read_hint": "app/Domain/Demo/Repositories/DemoRepository.php:1 [repository]",
                "fdr_role": "implementation",
                "chunk_role": "repository",
                "section": "DemoRepository.php",
                "document_status": "normal",
                "score": 0.52,
                "start_line": 1,
                "heading": "DemoRepository.php",
            },
            {
                "source": "migrations/20260101_demo.php",
                "read_hint": "migrations/20260101_demo.php:1 [migration]",
                "fdr_role": "implementation",
                "chunk_role": "migration",
                "section": "20260101_demo.php",
                "document_status": "normal",
                "score": 0.51,
                "start_line": 1,
                "heading": "20260101_demo.php",
            },
        ]
        profile = score_query_profile(
            "owner_caller_credentials caller_role missing repository audit",
            "implementation",
            None,
        )
        plan = build_read_plan(results, mode="implementation", profile=profile)
        self.assertEqual(plan["items"][0]["chunk_role"], "repository")

    def test_behavioral_deploy_task_prefers_runtime_implementation_over_compose_file(self) -> None:
        query = (
            "uploadComposeUpdate loses compose_override clickhouse_s3_mode bootstrap profiles "
            "and first rollout can overwrite runtime topology"
        )
        profile = score_query_profile(query, "implementation", None)
        implementation_boost = intent_source_multiplier(
            "app/Domain/ControlPlane/NodeUpdater.php",
            "php_file",
            "implementation",
            profile,
        )
        compose_boost = intent_source_multiplier(
            "docker-compose.override.yml",
            "yaml_config",
            "compose_config",
            profile,
        )
        results = [
            {
                "source": "docker-compose.override.yml",
                "read_hint": "docker-compose.override.yml:1 [implementation]",
                "fdr_role": "compose_config",
                "chunk_role": "implementation",
                "section": "docker-compose.override.yml",
                "document_status": "normal",
                "score": 0.90,
                "start_line": 1,
                "heading": "docker-compose.override.yml",
            },
            {
                "source": "app/Domain/ControlPlane/NodeUpdater.php",
                "read_hint": "app/Domain/ControlPlane/NodeUpdater.php:361 [implementation]",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "section": "NodeUpdater.php",
                "document_status": "normal",
                "score": 0.60,
                "start_line": 361,
                "heading": "NodeUpdater.php",
            },
        ]

        plan = build_read_plan(results, mode="implementation", profile=profile)

        self.assertTrue(profile["human_task"])
        self.assertIn("deploy_runtime", profile["human_intents"])
        self.assertGreater(implementation_boost, compose_boost)
        self.assertEqual(plan["items"][0]["source"], "app/Domain/ControlPlane/NodeUpdater.php")

    def test_section_anchor_multiplier_prefers_preview_with_exact_anchor(self) -> None:
        profile = {
            "mode": "frontend",
            "query_terms": {"target", "call", "expected_source_revision"},
            "review_terms": ["target.call", "expected_source_revision"],
        }
        self.assertGreater(
            section_anchor_multiplier(
                profile,
                "api_client",
                "visual-studio-assistant.ts",
                "targetCallPayload expected_source_revision attributes_merge",
            ),
            1.0,
        )
        self.assertEqual(
            section_anchor_multiplier(profile, "docs", "readme", "generic overview text"),
            1.0,
        )

    def test_markdown_path_references_create_cross_artifact_edges(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs").mkdir()
        (root / "app").mkdir()
        (root / "Docs" / "plan.md").write_text(
            "# Plan\n\nVerify app/Controller.php and tests/Feature/ControllerTest.php.",
            encoding="utf-8",
        )
        (root / "app" / "Controller.php").write_text("<?php\nfinal class Controller {}\n", encoding="utf-8")
        (root / "tests" / "Feature").mkdir(parents=True)
        (root / "tests" / "Feature" / "ControllerTest.php").write_text("<?php\n", encoding="utf-8")
        build_index(root)
        deps = lookup_deps(root, None, "app/Controller.php", direction="reverse")
        self.assertEqual(deps[0]["source"], "Docs/plan.md")
        self.assertEqual(deps[0]["kind"], "path_reference")

    def test_search_uses_path_tokens_and_source_diversity(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "matrices").mkdir()
        (root / "matrices" / "matrix.provider-feature-gate.v1.matrix.json").write_text(
            '{"capability":"install","status":"fixture required"}',
            encoding="utf-8",
        )
        (root / "docs").mkdir()
        (root / "docs" / "generic.md").write_text(
            "# Provider install\n\nProvider install readiness notes.\n\n## More\n\nProvider install details.",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps({"schema_version": "rag.config.v1", "search": {"max_chunks_per_source": 1}}),
            encoding="utf-8",
        )
        build_index(root)
        self.assertIn("provider", tokenize("matrix.provider-feature-gate.v1.matrix.json"))
        results = search_index(root, None, "provider feature matrix install", top_k=3)
        self.assertEqual(results[0]["source"], "matrices/matrix.provider-feature-gate.v1.matrix.json")
        self.assertEqual(len([item for item in results if item["source"] == "docs/generic.md"]), 1)

    def test_broad_implementation_query_prefers_local_rag_sources_over_policy_docs(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".mcp" / "rag-server" / "rag_universal").mkdir(parents=True)
        (root / "AGENTS.md").write_text(
            "# AGENTS\n\nrag search ranking chunking token cost " * 40,
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "README.md").write_text(
            "# Local RAG\n\nSearch quality, ranking, chunking, token cost and retrieval budget.",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "rag_universal" / "core.py").write_text(
            "def rank_chunks():\n    return 'search ranking chunking token cost'\n",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "force_include_globs": [
                        ".mcp/rag-server/*.md",
                        ".mcp/rag-server/rag_universal/*.py",
                        ".mcp/rag-server/**/*.md",
                        ".mcp/rag-server/**/*.py",
                    ],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "rag server ranking chunking token cost", top_k=3, mode="implementation")
        self.assertTrue(results[0]["source"].startswith(".mcp/rag-server/"))
        self.assertNotEqual(results[0]["source"], "AGENTS.md")

    def test_exact_filename_anchor_beats_semantic_frontend_neighbor(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components" / "admin" / "plugin-templates").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "schema").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "admin" / "plugin-templates" / "WidgetInstantiate.vue").write_text(
            "<script setup lang=\"ts\">\n"
            "const showPreview = true\n"
            "const generatedWidgetSchema = { component: 'PluginWidgetRenderer' }\n"
            "</script>\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "components" / "schema" / "SchemaDashboard.vue").write_text(
            "<script setup lang=\"ts\">\n"
            "const words = 'SchemaDashboard widget preview renderer dashboard schema pipeline '.repeat(20)\n"
            "</script>\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "WidgetInstantiate preview SchemaDashboard widget preview renderer pipeline"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/admin/plugin-templates/WidgetInstantiate.vue")
        self.assertGreater(results[0]["filename_match"], 0.0)

        planned = search_index_with_plan(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(
            planned["read_plan"]["items"][0]["source"],
            "uier-spa/src/components/admin/plugin-templates/WidgetInstantiate.vue",
        )
        self.assertIn(planned["read_plan"]["confidence"]["level"], {"medium", "high"})

    def test_non_rag_frontend_review_query_penalizes_local_rag_fixtures(self) -> None:
        profile = score_query_profile(
            "dashboard to dashboard SPA navigation reuses widget ids and stale response race accepts previous dashboard data",
            "frontend",
        )
        rag_fixture_multiplier = intent_source_multiplier(
            ".mcp/rag-server/tests/test_rag_universal.py",
            "python_file",
            "implementation",
            profile,
        )
        schema_dashboard_multiplier = intent_source_multiplier(
            "uier-spa/src/components/schema/SchemaDashboard.vue",
            "vue_file",
            "implementation",
            profile,
        )

        self.assertLess(rag_fixture_multiplier, 0.1)
        self.assertGreater(schema_dashboard_multiplier, 1.0)

    def test_knowledge_mode_prefers_curated_knowledge_pack(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Docs" / "knowledge" / "rag").mkdir(parents=True)
        (root / "Docs" / "visual").mkdir(parents=True)
        (root / "Docs" / "knowledge" / "rag" / "patterns.md").write_text(
            "# Patterns\n\nRoute contract owner boundary failure taxonomy query template.",
            encoding="utf-8",
        )
        (root / "Docs" / "visual" / "master-spec.md").write_text(
            "# Visual\n\nRoute contract owner boundary guidance for general product docs.",
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "route contract owner boundary failure taxonomy", top_k=2, mode="knowledge")
        self.assertEqual(results[0]["source"], "Docs/knowledge/rag/patterns.md")

    def test_self_rag_implementation_query_with_knowledge_terms_prefers_runtime_code(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".mcp" / "rag-server" / "rag_universal").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "knowledge" / "core-review").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "rag_universal" / "core.py").write_text(
            "def rerank_search_results():\n    return 'quality-check eval-quality knowledge-build rerank'\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "knowledge" / "core-review" / "owner-map.json").write_text(
            json.dumps({"note": "quality-check eval-quality knowledge-build rerank"}),
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "tests").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "tests" / "test_rag_universal.py").write_text(
            "def test_rag():\n    assert True\n",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "force_include_globs": [
                        ".mcp/rag-server/rag_universal/*.py",
                        ".mcp/rag-server/knowledge/**/*.json",
                        ".mcp/rag-server/tests/*.py",
                    ],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "quality-check eval-quality knowledge-build rerank", top_k=3, mode="implementation")
        self.assertEqual(results[0]["source"], ".mcp/rag-server/rag_universal/core.py")

    def test_self_rag_read_plan_prefers_runtime_layers_before_tests(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".mcp" / "rag-server" / "rag_universal").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "tests").mkdir(parents=True)
        (root / ".mcp" / "rag-server" / "rag_universal" / "core.py").write_text(
            "def chunk_budget():\n    return 'chunking overlap read plan budget'\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "rag_universal" / "cli.py").write_text(
            "def cli_budget():\n    return 'chunking overlap read plan budget'\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "tests" / "test_rag_universal.py").write_text(
            "def test_budget():\n    assert True\n",
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "force_include_globs": [
                        ".mcp/rag-server/rag_universal/*.py",
                        ".mcp/rag-server/tests/*.py",
                    ],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)
        payload = search_index_with_plan(root, None, "chunking overlap read plan budget", top_k=4, mode="implementation")
        self.assertTrue(payload["results"][0]["source"].startswith(".mcp/rag-server/rag_universal/"))
        self.assertTrue(payload["read_plan"]["items"][0]["source"].startswith(".mcp/rag-server/rag_universal/"))

    def test_self_rag_read_plan_does_not_promote_low_score_entrypoint_over_runtime(self) -> None:
        profile = score_query_profile("RAG search ranking read plan quality", "implementation", None)
        results = [
            {
                "source": ".mcp/rag-server/tools/rag.py",
                "read_hint": ".mcp/rag-server/tools/rag.py:1 [sql]",
                "fdr_role": "implementation",
                "chunk_role": "sql",
                "section": "rag.py",
                "document_status": "normal",
                "score": 0.25,
                "start_line": 1,
                "heading": "rag.py",
            },
            {
                "source": ".mcp/rag-server/rag_universal/core.py",
                "read_hint": ".mcp/rag-server/rag_universal/core.py:4438 [implementation]",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "section": "core.py",
                "document_status": "normal",
                "score": 2.0,
                "start_line": 4438,
                "heading": "core.py",
            },
        ]

        plan = build_read_plan(results, mode="implementation", profile=profile)

        self.assertTrue(profile["self_rag_code_intent"])
        self.assertEqual(plan["items"][0]["source"], ".mcp/rag-server/rag_universal/core.py")
        self.assertEqual(plan["confidence"]["top_score"], 2.0)
        self.assertGreaterEqual(plan["confidence"]["gap"], 0.0)

    def test_self_rag_fdr_read_plan_includes_companion_artifacts(self) -> None:
        profile = score_query_profile("RAG server FDR self-review exact_filename_boost read_plan config tests", "fdr", None)
        results = [
            {
                "source": ".mcp/rag-server/rag_universal/core.py",
                "read_hint": ".mcp/rag-server/rag_universal/core.py:4300 [implementation]",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "section": "core.py",
                "document_status": "normal",
                "score": 3.0,
                "start_line": 4300,
                "heading": "core.py",
            },
            {
                "source": ".mcp/rag-server/tests/test_rag_universal.py",
                "read_hint": ".mcp/rag-server/tests/test_rag_universal.py:1200 [test]",
                "fdr_role": "test",
                "chunk_role": "test",
                "section": "test_rag_universal.py",
                "document_status": "normal",
                "score": 0.8,
                "start_line": 1200,
                "heading": "test_rag_universal.py",
            },
            {
                "source": ".mcp/rag-server/schemas/rag.config.v1.schema.json",
                "read_hint": ".mcp/rag-server/schemas/rag.config.v1.schema.json:1 [implementation]",
                "fdr_role": "config",
                "chunk_role": "implementation",
                "section": "rag.config.v1.schema.json",
                "document_status": "normal",
                "score": 0.7,
                "start_line": 1,
                "heading": "rag.config.v1.schema.json",
            },
            {
                "source": ".mcp/rag-server/rag_universal/cli.py",
                "read_hint": ".mcp/rag-server/rag_universal/cli.py:1 [implementation]",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "section": "cli.py",
                "document_status": "normal",
                "score": 0.5,
                "start_line": 1,
                "heading": "cli.py",
            },
        ]

        plan = build_read_plan(results, mode="fdr", profile=profile)
        sources = [item["source"] for item in plan["items"]]

        self.assertEqual(sources[0], ".mcp/rag-server/rag_universal/core.py")
        self.assertEqual(sources[1], ".mcp/rag-server/tests/test_rag_universal.py")
        self.assertIn(".mcp/rag-server/tests/test_rag_universal.py", sources)
        self.assertIn(".mcp/rag-server/schemas/rag.config.v1.schema.json", sources)
        self.assertIn(".mcp/rag-server/rag_universal/cli.py", sources)
        self.assertIn("self-review", plan["token_budget_hint"])

    def test_self_rag_fdr_read_plan_adds_runtime_when_config_is_top_hit(self) -> None:
        profile = score_query_profile(
            "RAG server self-review config schema drift exact_filename_boost DEFAULT_CONFIG rag.config.example",
            "fdr",
            None,
        )
        results = [
            {
                "source": ".mcp/rag-server/rag.config.example.json",
                "read_hint": ".mcp/rag-server/rag.config.example.json:1 [implementation]",
                "fdr_role": "config",
                "chunk_role": "implementation",
                "section": "rag.config.example.json",
                "document_status": "normal",
                "score": 7.0,
                "start_line": 1,
                "heading": "rag.config.example.json",
            },
            {
                "source": ".mcp/rag-server/rag_universal/core.py",
                "read_hint": ".mcp/rag-server/rag_universal/core.py:1 [implementation]",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "section": "core.py",
                "document_status": "normal",
                "score": 0.8,
                "start_line": 1,
                "heading": "core.py",
            },
            {
                "source": ".mcp/rag-server/tests/test_rag_universal.py",
                "read_hint": ".mcp/rag-server/tests/test_rag_universal.py:1 [test]",
                "fdr_role": "test",
                "chunk_role": "test",
                "section": "test_rag_universal.py",
                "document_status": "normal",
                "score": 0.7,
                "start_line": 1,
                "heading": "test_rag_universal.py",
            },
            {
                "source": ".mcp/rag-server/schemas/rag.config.v1.schema.json",
                "read_hint": ".mcp/rag-server/schemas/rag.config.v1.schema.json:1 [implementation]",
                "fdr_role": "config",
                "chunk_role": "implementation",
                "section": "rag.config.v1.schema.json",
                "document_status": "normal",
                "score": 0.6,
                "start_line": 1,
                "heading": "rag.config.v1.schema.json",
            },
        ]

        plan = build_read_plan(results, mode="fdr", profile=profile)
        sources = [item["source"] for item in plan["items"]]

        self.assertEqual(sources[0], ".mcp/rag-server/rag.config.example.json")
        self.assertIn(".mcp/rag-server/rag_universal/core.py", sources)
        self.assertIn(".mcp/rag-server/tests/test_rag_universal.py", sources)
        self.assertIn(".mcp/rag-server/schemas/rag.config.v1.schema.json", sources)

    def test_self_rag_fdr_result_selection_keeps_companion_config_and_tests(self) -> None:
        profile = score_query_profile(
            "RAG server self-review config schema drift exact_filename_boost DEFAULT_CONFIG rag.config.example",
            "fdr",
            None,
        )
        results = [
            {
                "source": ".mcp/rag-server/rag.config.example.json",
                "fdr_role": "config",
                "chunk_role": "implementation",
                "heading": "rag.config.example.json",
                "document_status": "normal",
                "score": 7.0,
                "filename_match": 1.0,
                "path_match": 0.0,
                "start_line": 1,
            },
            {
                "source": ".mcp/rag-server/schemas/rag.config.v1.schema.json",
                "fdr_role": "config",
                "chunk_role": "implementation",
                "heading": "rag.config.v1.schema.json",
                "document_status": "normal",
                "score": 3.0,
                "filename_match": 0.0,
                "path_match": 0.0,
                "start_line": 1,
            },
            {
                "source": ".mcp/rag-server/rag_universal/core.py",
                "fdr_role": "implementation",
                "chunk_role": "implementation",
                "heading": "core.py",
                "document_status": "normal",
                "score": 0.8,
                "filename_match": 0.0,
                "path_match": 0.0,
                "start_line": 1,
            },
            {
                "source": ".mcp/rag-server/tests/test_rag_universal.py",
                "fdr_role": "test",
                "chunk_role": "test",
                "heading": "test_rag_universal.py",
                "document_status": "normal",
                "score": 0.7,
                "filename_match": 0.0,
                "path_match": 0.0,
                "start_line": 1,
            },
        ]

        selected = select_search_results(results, top_k=4, max_chunks_per_source=1, mode="fdr", profile=profile)
        sources = [item["source"] for item in selected]

        self.assertEqual(sources[0], ".mcp/rag-server/rag.config.example.json")
        self.assertIn(".mcp/rag-server/rag_universal/core.py", sources)
        self.assertIn(".mcp/rag-server/tests/test_rag_universal.py", sources)
        self.assertIn(".mcp/rag-server/schemas/rag.config.v1.schema.json", sources)

    def test_dotted_filename_anchor_matches_config_example_without_extension(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".mcp" / "rag-server" / "rag_universal").mkdir(parents=True)
        (root / ".mcp" / "rag-server").mkdir(parents=True, exist_ok=True)
        (root / ".mcp" / "rag-server" / "rag_universal" / "core.py").write_text(
            "exact_filename_boost read_plan config schema\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "rag.config.example.json").write_text(
            json.dumps({"search": {"exact_filename_boost": 1.05}}),
            encoding="utf-8",
        )
        (root / "rag.config.json").write_text(
            json.dumps(
                {
                    "schema_version": "rag.config.v1",
                    "force_include_globs": [
                        ".mcp/rag-server/rag_universal/*.py",
                        ".mcp/rag-server/*.json",
                    ],
                }
            ),
            encoding="utf-8",
        )
        build_index(root)

        results = search_index(root, None, "RAG server config rag.config.example exact_filename_boost", top_k=2, mode="fdr")

        self.assertEqual(results[0]["source"], ".mcp/rag-server/rag.config.example.json")
        self.assertGreater(results[0]["filename_match"], 0.0)

    def test_review_comment_query_prefers_shell_script_over_plan_noise(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "bin").mkdir(parents=True)
        (root / "Docs" / "plans").mkdir(parents=True)
        (root / ".mcp" / "rag-server").mkdir(parents=True)
        (root / "bin" / "build_and_push_node_images.sh").write_text(
            "#!/usr/bin/env bash\nset -u\ndeclare -A V1_ALLOWED=([\"core-api\"]=1)\n",
            encoding="utf-8",
        )
        (root / "Docs" / "plans" / "node-images.md").write_text(
            "Task build and push script for rollout. macOS Bash 3.2 contract notes.\n",
            encoding="utf-8",
        )
        (root / ".mcp" / "rag-server" / "rag.config.example.json").write_text(
            json.dumps({"bash": ["set -u", "declare", "shell script"]}),
            encoding="utf-8",
        )
        build_index(root)
        query = "на macOS Bash 3.2 declare -A V1_ALLOWED это не associative array line 153 core unbound variable build_and_push_node_images"
        results = search_index(root, None, query, top_k=3, mode="implementation")
        self.assertEqual(results[0]["source"], "bin/build_and_push_node_images.sh")

    def test_review_comment_query_prefers_controller_for_utf8_truncation_finding(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "app" / "Http" / "Controllers").mkdir(parents=True)
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "Docs" / "specs").mkdir(parents=True)
        (root / "app" / "Http" / "Controllers" / "ControlPlaneNodeController.php").write_text(
            "<?php\n$auditMessage = 'Rollout queued';\nif (strlen($auditMessage) > 255) { $auditMessage = substr($auditMessage, 0, 252) . '...'; }\n",
            encoding="utf-8",
        )
        (root / "tests" / "Unit" / "ControlPlaneRolloutNodesTest.php").write_text(
            "<?php\nfunction test_rollout(): void { assert(true); }\n",
            encoding="utf-8",
        )
        (root / "Docs" / "specs" / "rollout.md").write_text(
            "Audit reason VARCHAR(255) utf8mb4 contract.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "audit message truncation strlen substr UTF-8 corruption utf8mb4 VARCHAR(255) ControlPlaneNodeController rolloutImages"
        results = search_index(root, None, query, top_k=3, mode="implementation")
        self.assertEqual(results[0]["source"], "app/Http/Controllers/ControlPlaneNodeController.php")

    def test_review_comment_query_prefers_controller_for_target_node_ids_finding(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "app" / "Http" / "Controllers").mkdir(parents=True)
        (root / "Docs" / "plans").mkdir(parents=True)
        (root / "tests" / "Unit").mkdir(parents=True)
        (root / "app" / "Http" / "Controllers" / "ControlPlaneNodeController.php").write_text(
            "<?php\nfunction prepareRolloutPayload(array $payload): array {}\nfunction resolveExplicitRolloutTargets(array $ids): array { return $ids; }\n// target_node_ids array unbounded N+1 queries one rollout submit\n",
            encoding="utf-8",
        )
        (root / "Docs" / "plans" / "rollout.md").write_text(
            "Task 4 rollout API create one update_node job per target.\n",
            encoding="utf-8",
        )
        (root / "tests" / "Unit" / "ControlPlaneRolloutNodesTest.php").write_text(
            "<?php\nfunction test_rollout_targets(): void { assert(true); }\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "target_node_ids array unbounded 1000 UUIDs resolveExplicitRolloutTargets N+1 query pattern one rollout submit"
        results = search_index(root, None, query, top_k=3, mode="implementation")
        self.assertEqual(results[0]["source"], "app/Http/Controllers/ControlPlaneNodeController.php")

    def test_frontend_review_comment_query_prefers_widget_source_over_review_docs(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "SandboxesWidget.vue").write_text(
            "<script setup>\nconst responseData = response.data?.data ?? response.data\nconst items = responseData?.items ?? []\n</script>\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "review.md").write_text(
            "SandboxesWidget response.data.items interface API returns data schema data items always empty list.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "SandboxesWidget response.data.items interface API returns data schema data items always empty list"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/SandboxesWidget.vue")

    def test_frontend_review_comment_query_prefers_schema_form_source_over_review_docs(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "SchemaForm.vue").write_text(
            "<script setup>\nconst endpoint = '/v1/interfaces/admin/' + field.options.endpoint\nconst params = field.options.params\n</script>\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "history.md").write_text(
            "SchemaForm dynamic select options endpoint forcibly converted to /v1/interfaces/admin and ignores options.params.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "SchemaForm dynamic select options endpoint forcibly converted to /v1/interfaces/admin and ignores options.params"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/SchemaForm.vue")

    def test_frontend_review_comment_query_prefers_schema_dashboard_source_over_tests(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components" / "schema").mkdir(parents=True)
        (root / "uier-spa" / "src" / "tests" / "components").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "schema" / "SchemaDashboard.vue").write_text(
            "<script setup>\nconst widgetGenerations = new Map()\nconst nextWidgetId = `${definition.id}-${index}`\n</script>\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "tests" / "components" / "SchemaDashboard.test.ts").write_text(
            "describe('SchemaDashboard', () => { it('renders widgets', () => {}) })\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "dashboard.md").write_text(
            "SchemaDashboard widget registry reuses the same widget id across multiple cards and breaks refresh isolation.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "SchemaDashboard widget registry reuses the same widget id across multiple cards and breaks refresh isolation"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/schema/SchemaDashboard.vue")

    def test_frontend_review_comment_query_prefers_relation_editor_over_unrelated_views(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components" / "visual-studio" / "entity").mkdir(parents=True)
        (root / "uier-spa" / "src" / "views" / "visual-studio").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "visual-studio" / "entity" / "RelationEditor.vue").write_text(
            "<script setup>\nconst allowSelfLink = relation.allow_self_link === true\n</script>\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "views" / "visual-studio" / "CompositionMapView.vue").write_text(
            "<script setup>\nconst relationMap = []\n</script>\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "relations.md").write_text(
            "same-type relation self-link allow_self_link flag UI blocks it and relation editor prevents linking an entity type to itself.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "same-type relation self-link allow_self_link flag UI blocks it and relation editor prevents linking an entity type to itself"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/visual-studio/entity/RelationEditor.vue")

    def test_frontend_review_comment_query_prefers_visual_studio_api_over_tests(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "api").mkdir(parents=True)
        (root / "uier-spa" / "src" / "tests" / "api").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "uier-spa" / "src" / "api" / "visual-studio-assistant.ts").write_text(
            "export function normalizeTargetCall(payload) { return payload.target.call?.attributes ?? payload.target.call }\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "tests" / "api" / "visual-studio-assistant.test.ts").write_text(
            "describe('assistant', () => { it('normalizes target.call', () => {}) })\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "assistant.md").write_text(
            "CAS detection misses target.call update because comparison only inspects top-level request object and not nested payload.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "CAS detection misses target.call update because comparison only inspects top-level request object and not nested payload"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/api/visual-studio-assistant.ts")

    def test_frontend_review_comment_query_prefers_visual_studio_api_over_review_docs(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "api").mkdir(parents=True)
        (root / "Docs" / "reviews").mkdir(parents=True)
        (root / "uier-spa" / "src" / "api" / "visual-studio-automations.ts").write_text(
            "export function projectAutomationsPath(projectId) { return `/v1/automation-core/definitions?project_id=${projectId}` }\n",
            encoding="utf-8",
        )
        (root / "Docs" / "reviews" / "visual-studio.md").write_text(
            "project automation builder still calls legacy /projects/{projectId}/automations route instead of canonical visual studio automation endpoint.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "project automation builder still calls legacy /projects/{projectId}/automations route instead of canonical visual studio automation endpoint"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/api/visual-studio-automations.ts")

    def test_frontend_review_comment_query_prefers_schema_dashboard_without_exact_filename(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "components" / "schema").mkdir(parents=True)
        (root / "uier-spa" / "src" / "tests" / "components").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "dashboard" / "widgets").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "schema" / "SchemaDashboard.vue").write_text(
            "<script setup>\nconst widgetId = `${dashboard.id}-${widget.key}`\nconst activeDashboardId = props.dashboardId\n</script>\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "tests" / "components" / "dashboard-widgets.test.ts").write_text(
            "describe('dashboard widgets', () => { it('renders stats', () => {}) })\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "components" / "dashboard" / "widgets" / "AdminStatsWidget.vue").write_text(
            "<script setup>\nconst stats = []\n</script>\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "dashboard to dashboard SPA navigation reuses widget ids and stale response race accepts previous dashboard data for summary stats table widgets"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/components/schema/SchemaDashboard.vue")

    def test_frontend_review_comment_query_prefers_assistant_api_for_attributes_merge_risk(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "api").mkdir(parents=True)
        (root / "uier-spa" / "src" / "tests" / "stores" / "visual-studio").mkdir(parents=True)
        (root / "Docs" / "guides").mkdir(parents=True)
        (root / "uier-spa" / "src" / "api" / "visual-studio-assistant.ts").write_text(
            "export function normalizeAttributesMerge(payload) { return payload.attributes_merge ?? payload.attributes }\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "tests" / "stores" / "visual-studio" / "automation-builder.test.ts").write_text(
            "describe('automation builder', () => { it('normalizes assistant payload', () => {}) })\n",
            encoding="utf-8",
        )
        (root / "Docs" / "guides" / "visual-studio-user-guide.md").write_text(
            "repair AI normalization mixes explicit attributes with flat keys and can mask full attributes replace risk instead of safe attributes_merge.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "repair AI normalization mixes explicit attributes with flat keys and can mask full attributes replace risk instead of safe attributes_merge"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/api/visual-studio-assistant.ts")

    def test_frontend_lexicon_boost_prefers_assistant_api_over_devtools_noise(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "api").mkdir(parents=True)
        (root / "uier" / "plugins" / "devtools" / "backend" / "Mcp").mkdir(parents=True)
        (root / "uier" / "plugins" / "devtools" / "backend" / "Support").mkdir(parents=True)
        (root / "uier-spa" / "src" / "api" / "visual-studio-assistant.ts").write_text(
            "export function normalizeAttributesMerge(payload) { return payload.attributes_merge ?? payload.target.call }\n",
            encoding="utf-8",
        )
        (root / "uier" / "plugins" / "devtools" / "backend" / "Mcp" / "DocsContentBuilder.php").write_text(
            "<?php\nfunction buildDocs(): array { return ['target.call', 'entity_operation', 'expected_source_revision']; }\n",
            encoding="utf-8",
        )
        (root / "uier" / "plugins" / "devtools" / "backend" / "Support" / "MspCapabilityRegistry.php").write_text(
            "<?php\nfunction capabilities(): array { return ['attributes_merge', 'target.call']; }\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "local CAS validation warns for core.update but misses canonical target.call entity_operation update with expected_source_revision and later conflict handler"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/api/visual-studio-assistant.ts")

    def test_frontend_attributes_merge_query_downranks_devtools_noise(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier-spa" / "src" / "api").mkdir(parents=True)
        (root / "uier" / "plugins" / "devtools" / "backend" / "Support").mkdir(parents=True)
        (root / "uier" / "plugins" / "devtools" / "backend" / "Mcp").mkdir(parents=True)
        (root / "uier-spa" / "src" / "api" / "visual-studio-assistant.ts").write_text(
            "export function normalizeWorkflowPartialUpdateStep(step) { return step.attributes_merge ?? step.target?.call }\n",
            encoding="utf-8",
        )
        (root / "uier" / "plugins" / "devtools" / "backend" / "Support" / "MspCapabilityRegistry.php").write_text(
            "<?php\nfunction capability(): array { return ['attributes_merge', 'entity_operation:update', 'target.call', 'expected_source_revision']; }\n",
            encoding="utf-8",
        )
        (root / "uier" / "plugins" / "devtools" / "backend" / "Mcp" / "DocsContentBuilder.php").write_text(
            "<?php\nfunction docs(): string { return 'attributes_merge target.call expected_source_revision core.update'; }\n",
            encoding="utf-8",
        )
        build_index(root)
        query = "repair AI normalization mixes explicit attributes with flat keys and can mask full attributes replace risk instead of safe attributes_merge"
        results = search_index(root, None, query, top_k=3, mode="frontend")
        self.assertEqual(results[0]["source"], "uier-spa/src/api/visual-studio-assistant.ts")

    def test_human_task_profile_detects_multilingual_access_problem(self) -> None:
        query = (
            "Користувач з роллю viewer проходить SPA route, але отримує 403 на API. "
            "Схоже, BFF requireRoles відсікає доступ до того, як plugin route policy перевірить roles_any."
        )
        profile = score_query_profile(query, "implementation", None)
        self.assertTrue(profile["human_task"])
        self.assertIn("access_auth", profile["human_intents"])
        self.assertIn("routing_api", profile["human_intents"])

    def test_review_profile_takes_precedence_over_human_task(self) -> None:
        query = (
            "HIGH actual expected failure route payload race stale line 42. "
            "Target file: app/Http/Controllers/ControlPlaneNodeController.php. "
            "resolveExplicitRolloutTargets target_node_ids unbounded N+1 query pattern one rollout submit."
        )
        profile = score_query_profile(query, "implementation", None)
        self.assertTrue(profile["review_comment"])
        self.assertFalse(profile["human_task"])

    def test_human_task_query_prefers_bff_contract_sources_over_ui_noise(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "uier" / "app" / "Http" / "Controllers").mkdir(parents=True)
        (root / "plugins" / "data-tables-3").mkdir(parents=True)
        (root / "uier-spa" / "src" / "router").mkdir(parents=True)
        (root / "uier-spa" / "src" / "components" / "data-tables").mkdir(parents=True)
        (root / "uier" / "app" / "Http" / "Controllers" / "AdminPluginProxyController.php").write_text(
            "<?php\nfinal class AdminPluginProxyController {\n"
            "private const RUNTIME_ROLES = ['operator', 'admin'];\n"
            "public function pluginRuntime(): void { $this->requireRoles(self::RUNTIME_ROLES); }\n}\n",
            encoding="utf-8",
        )
        (root / "plugins" / "data-tables-3" / "plugin.yaml").write_text(
            "http_routes:\n  workbooks.show:\n    roles_any: [viewer, operator, admin]\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "router" / "index.ts").write_text(
            "export const routes = [{ path: '/admin/data-tables-3/workbooks/:workbookId', meta: { roles: ['viewer', 'operator', 'admin'] } }]\n",
            encoding="utf-8",
        )
        (root / "uier-spa" / "src" / "components" / "data-tables" / "WorkbookGrid.vue").write_text(
            "<template><div>viewer operator admin workbook table visible in UI</div></template>\n",
            encoding="utf-8",
        )
        build_index(root)
        query = (
            "viewer проходить SPA route для workbook, але отримує 403 на API. "
            "Потрібно знайти де BFF або proxy gate відсікає роль до core route policy roles_any."
        )
        results = search_index(root, None, query, top_k=5, mode="implementation")
        self.assertEqual(results[0]["source"], "uier/app/Http/Controllers/AdminPluginProxyController.php")
        self.assertIn("plugins/data-tables-3/plugin.yaml", {item["source"] for item in results[:4]})

    def test_human_task_query_expands_russian_concurrency_terms(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "app" / "Domain" / "ControlPlane" / "OwnerV2" / "Repositories").mkdir(parents=True)
        (root / "Docs" / "notes").mkdir(parents=True)
        (root / "app" / "Domain" / "ControlPlane" / "OwnerV2" / "Repositories" / "OwnerAuditChainRepository.php").write_text(
            "<?php\nfinal class OwnerAuditChainRepository {\n"
            "public function verifyChainIntegrity(): bool { return $this->walkByPrevHash('GENESIS_PREV_HASH', 'entry_hash', 'prev_hash'); }\n}\n",
            encoding="utf-8",
        )
        (root / "Docs" / "notes" / "audit.md").write_text(
            "General audit chain overview for operators.\n",
            encoding="utf-8",
        )
        build_index(root)
        query = (
            "При одновременной записи audit chain может быть гонка: проверка идет не по prev_hash "
            "и entry_hash, поэтому цепочка аудита ложно ломается при одинаковом timestamp."
        )
        results = search_index(root, None, query, top_k=3, mode="implementation")
        self.assertEqual(
            results[0]["source"],
            "app/Domain/ControlPlane/OwnerV2/Repositories/OwnerAuditChainRepository.php",
        )

    def test_eval_quality_compares_rag_and_baseline(self) -> None:
        root = self.make_project()
        build_index(root)
        cases = root / "cases.json"
        cases.write_text(
            json.dumps(
                [
                    {
                        "id": "stop_guard",
                        "query": "strict stop guard",
                        "expected_sources": ["README.md"],
                    }
                ]
            ),
            encoding="utf-8",
        )
        report = evaluate_quality(root, None, cases)
        self.assertEqual(report["summary"]["rag"]["top1"], 1)
        self.assertIn("baseline", report["summary"])
        rag_only = evaluate_quality(root, None, cases, include_baseline=False, include_cases=False)
        self.assertEqual(rag_only["summary"]["rag"]["top1"], 1)
        self.assertIsNone(rag_only["summary"]["baseline"])
        self.assertEqual(rag_only["cases"], [])

    def test_evaluate_case_rows_uses_case_specific_mode(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        cases = [
            {
                "id": "frontend-widget-race",
                "query": "dashboard widget stale response race",
                "mode": "frontend",
                "expected_sources": ["uier-spa/src/components/schema/SchemaDashboard.vue"],
            }
        ]

        def fake_search(
            _root: Path,
            _config_path: str | Path | None,
            _query: str,
            top_k: int = 10,
            mode: str = "default",
        ) -> list[dict[str, object]]:
            if mode == "frontend":
                return [{"source": "uier-spa/src/components/schema/SchemaDashboard.vue"}]
            return [{"source": "Docs/README.md"}]

        with mock.patch("rag_universal.eval_quality.search_index", side_effect=fake_search):
            report = evaluate_case_rows(root, None, cases, [], include_baseline=False)

        self.assertEqual(report["summary"]["rag"]["top1"], 1)
        self.assertEqual(report["cases"][0]["mode"], "frontend")

    def test_benchmark_quality_reports_latency_and_token_metrics(self) -> None:
        root = self.make_project()
        build_index(root)
        cases = root / "cases.json"
        cases.write_text(
            json.dumps(
                [
                    {
                        "id": "stop_guard",
                        "query": "strict stop guard",
                        "expected_sources": ["README.md"],
                    }
                ]
            ),
            encoding="utf-8",
        )
        report = benchmark_quality(root, None, cases, top_k=3, mode="frontend")
        self.assertEqual(report["schema_version"], "rag.quality-benchmark.v1")
        self.assertEqual(report["benchmark_profile"], "frontend")
        self.assertIn("latency_ms_avg", report["summary"]["rag"])
        self.assertIn("tokens_avg", report["summary"]["rag"])
        self.assertIn("delta", report["summary"])
        self.assertIn(report["verdict"]["status"], {"pass", "fail"})
        self.assertIn("max_latency_p95_ms", report["verdict"]["thresholds"])
        self.assertTrue(report["cases"])

        tool = ROOT / "tools" / "rag.py"
        cli = subprocess.run(
            [
                sys.executable,
                str(tool),
                "benchmark-quality",
                "--root",
                str(root),
                "--cases",
                str(cases),
                "--summary-only",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        payload = json.loads(cli.stdout)
        self.assertEqual(payload["schema_version"], "rag.quality-benchmark.v1")
        self.assertEqual(payload["cases"], [])
        self.assertIn("verdict", payload)

    def test_benchmark_quality_recovers_from_sqlite_error_with_search_cache_rebuild(self) -> None:
        root = self.make_project()
        build_index(root)
        cases = root / "cases.json"
        cases.write_text(
            json.dumps(
                [
                    {
                        "id": "stop_guard",
                        "query": "strict stop guard",
                        "expected_sources": ["README.md"],
                    }
                ]
            ),
            encoding="utf-8",
        )
        good_payload = {
            "results": [{"source": "README.md"}],
            "read_plan": {"items": [{"source": "README.md", "read_hint": "README.md:1"}]},
        }
        with mock.patch(
            "rag_universal.eval_quality.search_index_with_plan",
            side_effect=[sqlite3.DatabaseError("database disk image is malformed"), good_payload],
        ), mock.patch("rag_universal.eval_quality.rebuild_search_cache", return_value=True) as mocked_rebuild, mock.patch(
            "rag_universal.eval_quality.build_index"
        ) as mocked_build:
            report = benchmark_quality(root, None, cases, top_k=3, include_cases=False)
        mocked_rebuild.assert_called_once()
        mocked_build.assert_not_called()
        self.assertEqual(report["summary"]["rag"]["top1"], 1)

    def test_benchmark_quality_falls_back_to_full_rebuild_when_search_cache_rebuild_fails(self) -> None:
        root = self.make_project()
        build_index(root)
        cases = root / "cases.json"
        cases.write_text(
            json.dumps(
                [
                    {
                        "id": "stop_guard",
                        "query": "strict stop guard",
                        "expected_sources": ["README.md"],
                    }
                ]
            ),
            encoding="utf-8",
        )
        good_payload = {
            "results": [{"source": "README.md"}],
            "read_plan": {"items": [{"source": "README.md", "read_hint": "README.md:1"}]},
        }
        with mock.patch(
            "rag_universal.eval_quality.search_index_with_plan",
            side_effect=[sqlite3.DatabaseError("database disk image is malformed"), good_payload],
        ), mock.patch("rag_universal.eval_quality.rebuild_search_cache", return_value=False) as mocked_rebuild, mock.patch(
            "rag_universal.eval_quality.build_index"
        ) as mocked_build:
            report = benchmark_quality(root, None, cases, top_k=3, include_cases=False)
        mocked_rebuild.assert_called_once()
        mocked_build.assert_called_once()
        self.assertEqual(report["summary"]["rag"]["top1"], 1)

    def test_resolve_benchmark_profile_uses_mode_specific_defaults(self) -> None:
        config = {
            "benchmark_profiles": {
                "default": {
                    "min_cases": 5,
                    "min_top3_ratio": 0.6,
                    "min_mrr": 0.4,
                    "max_latency_p95_ms": 20000.0,
                    "max_tokens_avg": 5000.0,
                },
                "frontend": {
                    "min_cases": 5,
                    "min_top3_ratio": 0.7,
                    "min_mrr": 0.55,
                    "max_latency_p95_ms": 18000.0,
                    "max_tokens_avg": 2500.0,
                },
                "implementation": {
                    "min_cases": 5,
                    "min_top3_ratio": 0.7,
                    "min_mrr": 0.55,
                    "max_latency_p95_ms": 15000.0,
                    "max_tokens_avg": 2500.0,
                },
            }
        }
        profile = resolve_benchmark_profile(config, "frontend", "auto", 5, 0.6, 0.4, 20000.0, 5000.0)
        self.assertEqual(profile["name"], "frontend")
        self.assertEqual(profile["thresholds"]["max_tokens_avg"], 2500.0)
        explicit = resolve_benchmark_profile(config, "frontend", "implementation", 5, 0.6, 0.4, 20000.0, 5000.0)
        self.assertEqual(explicit["name"], "implementation")

    def test_quality_check_generates_comparative_metrics(self) -> None:
        root = self.make_project()
        build_index(root)
        report = quality_check(root, None, case_limit=4, top_k=5, mode="default", include_cases=True, min_cases=4)
        self.assertEqual(report["schema_version"], "rag.quality-check.v1")
        self.assertEqual(report["case_source"], "generated-from-index")
        self.assertEqual(report["health"]["cases"], 4)
        self.assertFalse(report["health"]["index_stale_after_check"])
        self.assertEqual(report["summary"]["rag"]["total"], 4)
        self.assertIsNotNone(report["summary"]["baseline"])
        self.assertIn("delta", report["summary"])
        self.assertIn(report["verdict"]["status"], {"pass", "fail"})
        self.assertTrue(report["cases"])

        tool = ROOT / "tools" / "rag.py"
        cli = subprocess.run(
            [
                sys.executable,
                str(tool),
                "quality-check",
                "--root",
                str(root),
                "--case-limit",
                "3",
                "--min-cases",
                "3",
                "--summary-only",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        payload = json.loads(cli.stdout)
        self.assertEqual(payload["health"]["cases"], 3)
        self.assertEqual(payload["cases"], [])

    def test_generated_query_terms_anchor_ambiguous_support_artifacts(self) -> None:
        rag_readme = generated_query_terms(
            {
                "source": ".mcp/rag-server/README.md",
                "heading": "Universal RAG Experimental",
                "text": "Reusable local RAG toolkit with quality checks and MCP server.",
            },
            set(),
        )
        docs_readme = generated_query_terms(
            {
                "source": "Docs/README.md",
                "heading": "Project documentation",
                "text": "Documentation overview and generated indexes.",
            },
            set(),
        )
        app_code = generated_query_terms(
            {
                "source": "app/Services/SearchPlanner.php",
                "heading": "SearchPlanner",
                "text": "Search planner builds weighted query candidates for application code.",
            },
            set(),
        )

        self.assertEqual(rag_readme[0], ".mcp/rag-server/README.md")
        self.assertEqual(docs_readme[0], "Docs/README.md")
        self.assertNotEqual(app_code[0], "app/Services/SearchPlanner.php")

    def test_cyrillic_query_expansion(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "README.md").write_text(
            "# Safety\n\nDestructive command guard blocks dangerous shell operations.",
            encoding="utf-8",
        )
        (root / "notes.md").write_text("# Notes\n\nGeneral command reference.", encoding="utf-8")
        build_index(root)
        results = search_index(root, None, "захист небезпечних команд", top_k=1)
        self.assertEqual(results[0]["source"], "README.md")

    def test_knowledge_build_generates_lessons_patterns_and_owner_map(self) -> None:
        root = self.make_project()
        cases = root / "review-cases.json"
        cases.write_text(
            json.dumps(
                [
                    {
                        "id": "case-1",
                        "pr": 12,
                        "author": "leonextra",
                        "kind": "review",
                        "query": (
                            "PR #12 review evidence. Target file: uier-spa/src/components/schema/SchemaForm.vue. "
                            "Cited files: uier-spa/src/components/schema/SchemaForm.vue, "
                            "plugins/core-admin/schemas/helpers/form.yaml. Context: HIGH SchemaForm ignores "
                            "options.params and breaks schema dynamic select endpoint contract."
                        ),
                        "expected_sources": ["uier-spa/src/components/schema/SchemaForm.vue"],
                    },
                    {
                        "id": "case-2",
                        "pr": 5,
                        "author": "leonextra",
                        "kind": "review",
                        "query": (
                            "MEDIUM MonitoringController restartWorker has command injection risk. "
                            "Target file: uier/app/Http/Controllers/MonitoringController.php."
                        ),
                        "expected_sources": ["uier/app/Http/Controllers/MonitoringController.php"],
                    },
                ]
            ),
            encoding="utf-8",
        )
        rules = root / "knowledge.rules.json"
        rules.write_text(
            json.dumps({"owner_rules": [{"prefix": "uier-spa/", "owner": "UIer SPA", "scope": "frontend"}]}),
            encoding="utf-8",
        )
        summary = build_project_knowledge(root, cases, "Docs/knowledge/rag", "demo", rules)
        out_dir = root / "Docs" / "knowledge" / "rag"
        self.assertEqual(summary["lessons"], 2)
        self.assertEqual(summary["schema_version"], "rag.knowledge-summary.v1")
        self.assertEqual(summary["cases_path"], "review-cases.json")
        self.assertEqual(summary["rules_sha256"], knowledge_pack_status(root, "Docs/knowledge/rag")["summary"]["rules_sha256"])
        self.assertEqual(summary["rules_path"], "knowledge.rules.json")
        self.assertFalse(knowledge_pack_status(root, "Docs/knowledge/rag")["stale"])
        self.assertTrue((out_dir / "lessons.jsonl").exists())
        self.assertTrue((out_dir / "patterns.md").exists())
        self.assertTrue((out_dir / "failure-taxonomy.md").exists())
        self.assertTrue((out_dir / "owner-map.md").exists())
        lesson = json.loads((out_dir / "lessons.jsonl").read_text(encoding="utf-8").splitlines()[0])
        self.assertIn("schema_form_contract", lesson["categories"])
        self.assertIn("UIer SPA", [owner["owner"] for owner in lesson["owners"]])
        patterns = json.loads((out_dir / "patterns.json").read_text(encoding="utf-8"))
        categories = {row["category"] for row in patterns}
        self.assertIn("schema_form_contract", categories)
        self.assertIn("security_guard", categories)
        cases.write_text(json.dumps([]), encoding="utf-8")
        stale = knowledge_pack_status(root, "Docs/knowledge/rag")
        self.assertTrue(stale["stale"])
        self.assertIn("cases file changed", stale["reason"])

    def test_knowledge_mode_prioritizes_knowledge_pack(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "knowledge").mkdir()
        (root / "Docs").mkdir()
        (root / "knowledge" / "failure-taxonomy.md").write_text(
            "# RAG Failure Taxonomy\n\n## route_contract\n\nRoute contract owner boundary lesson.",
            encoding="utf-8",
        )
        (root / "Docs" / "generic.md").write_text(
            "# Route Notes\n\nRoute contract owner boundary lesson.",
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "route contract owner boundary lesson", top_k=2, mode="knowledge")
        self.assertEqual(results[0]["source"], "knowledge/failure-taxonomy.md")

    def test_knowledge_profile_generates_generic_rules_from_layout(self) -> None:
        root = self.make_project()
        (root / "routes").mkdir()
        (root / "tests").mkdir(exist_ok=True)
        summary = generate_project_profile(root, "rag.knowledge.json", "demo")
        self.assertGreaterEqual(summary["owner_rules"], 3)
        profile = json.loads((root / "rag.knowledge.json").read_text(encoding="utf-8"))
        prefixes = {item["prefix"] for item in profile["owner_rules"]}
        self.assertIn("src/", prefixes)
        self.assertIn("routes/", prefixes)
        self.assertIn("tests/", prefixes)


    def test_source_preview_chars_spec_md_yaml_expansion(self) -> None:
        self.assertEqual(source_preview_chars("docs/specs/2026-05-08-foundation.md", 500), 4000)
        self.assertEqual(source_preview_chars("Docs/Specs/ARCHITECTURE.md", 500), 4000)
        self.assertEqual(source_preview_chars("README.md", 500), 2000)
        self.assertEqual(source_preview_chars("src/Controller.php", 500), 500)
        self.assertEqual(source_preview_chars("schema.yaml", 500), 2000)
        self.assertEqual(source_preview_chars("config.yml", 500), 2000)
        # Preserves higher base_chars
        self.assertEqual(source_preview_chars("docs/specs/x.md", 6000), 6000)
        self.assertEqual(source_preview_chars("README.md", 3000), 3000)

    def test_spec_cross_cutting_detection_explicit_markers(self) -> None:
        # Q1-style: error codes + cross-cutting + spec
        p = score_query_profile(
            "error codes stale_capability_version capability_push_conflict "
            "cross-cutting Foundation spec federated architecture",
            "default",
        )
        self.assertTrue(p["spec_cross_cutting"])
        self.assertGreaterEqual(p["spec_cross_marker_hits"], 2)

    def test_spec_cross_cutting_detection_code_identifiers_t1(self) -> None:
        # Three error-code-suffixed identifiers + error anchor
        p = score_query_profile(
            "access_denied grant_push_conflict hmac_mismatch error handling in code",
            "implementation",
        )
        self.assertTrue(p["spec_cross_cutting"])

    def test_spec_cross_cutting_detection_code_identifiers_t2_spec_anchor(self) -> None:
        # capability + version suffixes + spec anchor
        p = score_query_profile(
            "stale_capability_version re_provision spec Foundation versioning",
            "implementation",
        )
        self.assertTrue(p["spec_cross_cutting"])

    def test_spec_cross_cutting_no_false_positive_plain_code_review(self) -> None:
        # Code review about capability/version gaps — NO spec anchor
        p = score_query_profile(
            "capability snapshot versioning gap stale handler pr88 review",
            "implementation",
        )
        self.assertFalse(p["spec_cross_cutting"])

    def test_spec_cross_cutting_not_triggered_for_frontend_mode(self) -> None:
        p = score_query_profile(
            "ErrorCode cross-cutting spec Foundation error codes",
            "frontend",
        )
        self.assertFalse(p["spec_cross_cutting"])

    def test_spec_cross_cutting_skip_broad_implementation_penalty(self) -> None:
        # spec_cross_cutting=True → broad_implementation penalty skipped → spec role not penalized
        # multiplier for spec role with spec anchor should be >= 1.0 (boosted, not penalized)
        profile = score_query_profile(
            "ErrorCode stale_capability_version cross-cutting Foundation spec error codes architecture",
            "default",
        )
        m = intent_source_multiplier("docs/specs/test.md", "markdown", "spec", profile)
        # Without the guard, broad_implementation would apply ×0.72 to role=spec → ~0.47 combined
        self.assertGreater(m, 0.80, f"spec role multiplier {m} should not be heavily penalized")

    def test_spec_cross_cutting_sort_key_score_based(self) -> None:
        profile = {"spec_cross_cutting": True}
        item = {"source": "docs/specs/x.md", "score": 0.95, "start_line": 10}
        config = {}
        key = profile_result_sort_key(item, config, profile)
        # Exact path/filename priority is flat, then spec sorting remains score-based.
        self.assertEqual(key[0], 0.0)
        self.assertEqual(key[1], 0.0)
        self.assertLess(key[3], 0.0)  # -score for 0.95 is negative

    def test_check_regression_query_text_fallback_empty_string(self) -> None:
        # Simulation of the fix: q.get("query_text") or qid
        q_ok = {"id": "Q1", "query_text": "error codes", "expected": ["spec.md"], "rag_rank": 1}
        q_empty = {"id": "Q2", "query_text": "", "expected": ["code.php"], "rag_rank": 1}
        q_missing = {"id": "Q3", "expected": ["code.php"], "rag_rank": 1}
        self.assertEqual(q_ok.get("query_text") or q_ok["id"], "error codes")
        self.assertEqual(q_empty.get("query_text") or q_empty["id"], "Q2")
        self.assertEqual(q_missing.get("query_text") or q_missing["id"], "Q3")


if __name__ == "__main__":
    unittest.main()
