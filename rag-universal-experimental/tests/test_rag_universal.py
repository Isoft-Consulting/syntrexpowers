from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rag_universal.core import (
    DEFAULT_CONFIG,
    build_index,
    document_status,
    ensure_fresh_index,
    extract_query_paths,
    index_coverage,
    index_status,
    load_chunks,
    load_config,
    lookup_deps,
    lookup_symbol,
    search_index,
    search_index_with_plan,
    tokenize,
    token_counts,
    trim_query_counts,
    watch_index,
)
from rag_universal.eval_quality import evaluate_quality
from rag_universal.eval_quality import hit_rank
from rag_universal.eval_quality import quality_check
from rag_universal.knowledge import build_project_knowledge
from rag_universal.knowledge import generate_project_profile
from rag_universal.knowledge import knowledge_pack_status
from rag_universal.mcp_server import handle_message


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

    def test_example_config_preserves_runtime_excludes(self) -> None:
        example_config = json.loads((ROOT / "rag.config.example.json").read_text(encoding="utf-8"))
        self.assertTrue(set(DEFAULT_CONFIG["exclude_dirs"]).issubset(set(example_config["exclude_dirs"])))

        root = self.make_project()
        (root / "storage" / "payload" / "work_items").mkdir(parents=True)
        (root / "storage" / "payload" / "work_items" / "payload.json").write_text(
            '{"runtime":true}',
            encoding="utf-8",
        )
        loaded = load_config(root, ROOT / "rag.config.example.json")
        self.assertIn("storage", loaded["exclude_dirs"])

        build_index(root, ROOT / "rag.config.example.json")
        sources = {chunk["source"] for chunk in load_chunks(root / ".rag-index")}
        self.assertNotIn("storage/payload/work_items/payload.json", sources)

    def test_agent_install_exclude_dirs_snippet_preserves_safe_defaults(self) -> None:
        guide = (ROOT / "AGENT_INSTALL.md").read_text(encoding="utf-8")
        snippet = guide.split("If you override `exclude_dirs`", 1)[1].split("```json", 1)[1].split("```", 1)[0]
        documented_config = json.loads(snippet)
        self.assertTrue(set(DEFAULT_CONFIG["exclude_dirs"]).issubset(set(documented_config["exclude_dirs"])))

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

    def test_standalone_filename_queries_use_explicit_path_priority(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "schemas").mkdir()
        (root / "schemas" / "rag.chunk.v1.schema.json").write_text('{"title":"Chunk"}', encoding="utf-8")
        (root / "schemas" / "rag.dep-edge.v1.schema.json").write_text('{"title":"Dependency"}', encoding="utf-8")
        (root / "SPEC.md").write_text("# Spec\n\nUniversal RAG project contract.", encoding="utf-8")
        (root / "README.md").write_text("# General\n\nrag type string schema " * 20, encoding="utf-8")
        build_index(root)

        self.assertEqual(extract_query_paths("inspect rag.chunk.v1.schema.json schema"), ["rag.chunk.v1.schema.json"])
        self.assertEqual(search_index(root, None, "inspect rag.chunk.v1.schema.json schema", top_k=1)[0]["source"], "schemas/rag.chunk.v1.schema.json")
        self.assertEqual(search_index(root, None, "inspect spec.md universal rag", top_k=1)[0]["source"], "SPEC.md")

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

    def test_document_status_requires_status_marker_for_superseded_mentions(self) -> None:
        active_spec = "# Spec\n\nStatus: executable MVP\n\nSupports canonical/superseded status detection."
        draft_spec = "# Spec\n\nStatus: draft\n\nDecisions are intentionally not frozen yet."
        not_ready_spec = "# Plan\n\nStatus: not ready\n\nStill blocked by missing proofs."
        stale_spec = "# Old\n\nStatus: SUPERSEDED\n\nDo not implement from this report."
        self.assertEqual(document_status("SPEC.md", "Spec", active_spec), "implementation_ready")
        self.assertEqual(document_status("SPEC.md", "Spec", draft_spec), "normal")
        self.assertEqual(document_status("Docs/plan.md", "Plan", not_ready_spec), "normal")
        self.assertEqual(document_status("Docs/old.md", "Old", stale_spec), "superseded")

    def test_fdr_mode_prefers_install_docs_over_provider_example_snippets(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "rag-universal-experimental" / "examples").mkdir(parents=True)
        (root / "rag-universal-experimental" / "tests").mkdir(parents=True)
        (root / "rag-universal-experimental" / "AGENT_INSTALL.md").write_text(
            "# Agent Install Playbook\n\nUniversal RAG MCP for Codex, Claude, DeepSeek, and any stdio client.",
            encoding="utf-8",
        )
        (root / "rag-universal-experimental" / "README.md").write_text(
            "# Universal RAG\n\nModel-neutral MCP server for Codex, Claude, and DeepSeek.",
            encoding="utf-8",
        )
        (root / "rag-universal-experimental" / "examples" / "mcp.deepseek.json").write_text(
            '{"mcpServers":{"rag":{"command":"python3","args":["rag.py","serve-mcp"]}}}',
            encoding="utf-8",
        )
        (root / "rag-universal-experimental" / "tests" / "test_rag_universal.py").write_text(
            "def test_provider_neutral_rag():\n"
            "    query = 'universal rag mcp claude deepseek codex'\n",
            encoding="utf-8",
        )
        build_index(root)
        results = search_index(root, None, "universal rag mcp claude deepseek codex", top_k=4, mode="fdr")
        self.assertIn(
            results[0]["source"],
            {"rag-universal-experimental/AGENT_INSTALL.md", "rag-universal-experimental/README.md"},
        )
        self.assertNotEqual(results[0]["source"], "rag-universal-experimental/tests/test_rag_universal.py")
        self.assertNotEqual(results[0]["source"], "rag-universal-experimental/examples/mcp.deepseek.json")
        self.assertLess(
            next(item for item in results if item["source"].endswith("mcp.deepseek.json"))["source_penalty"],
            1.0,
        )

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

    def test_eval_quality_hits_are_exact_repo_relative_paths(self) -> None:
        self.assertEqual(hit_rank(["README.md"], ["README.md"]), 1)
        self.assertEqual(hit_rank(["src\\service.py"], ["src/service.py"]), 1)
        self.assertIsNone(hit_rank(["docs/README.md"], ["README.md"]))
        self.assertIsNone(hit_rank(["uier/routes/admin.php"], ["routes/admin.php"]))

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


if __name__ == "__main__":
    unittest.main()
