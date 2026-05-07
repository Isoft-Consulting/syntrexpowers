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

from rag_universal.core import build_index, index_coverage, index_status, load_chunks, lookup_deps, lookup_symbol, search_index, tokenize
from rag_universal.eval_quality import evaluate_quality
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
        self.assertEqual({"rag_search", "rag_reindex", "rag_status", "rag_coverage", "rag_symbol", "rag_deps"}, names)

        called = handle_message(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "rag_search", "arguments": {"query": "stop guard", "top_k": 1}},
            },
            str(root),
            None,
        )
        payload = json.loads(called["result"]["content"][0]["text"])
        self.assertEqual(payload[0]["source"], "README.md")

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


if __name__ == "__main__":
    unittest.main()
