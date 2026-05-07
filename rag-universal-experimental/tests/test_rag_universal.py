from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rag_universal.core import build_index, index_status, load_chunks, lookup_deps, lookup_symbol, search_index
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
        (root / "schemas").mkdir()
        (root / "schemas" / "demo.schema.json").write_text(
            json.dumps({"$id": "demo.schema.v1", "title": "Demo Schema"}),
            encoding="utf-8",
        )
        (root / ".env").write_text("API_TOKEN=should-not-be-indexed", encoding="utf-8")
        (root / ".mcp.json").write_text('{"authorization":"Bearer should-not-be-indexed"}', encoding="utf-8")
        (root / "node_modules").mkdir()
        (root / "node_modules" / "ignored.md").write_text("ignored dependency docs", encoding="utf-8")
        return root

    def test_index_excludes_secret_paths_and_generates_artifacts(self) -> None:
        root = self.make_project()
        manifest = build_index(root)
        self.assertEqual(manifest["num_files"], 3)
        self.assertGreaterEqual(manifest["num_chunks"], 3)
        chunks = load_chunks(root / ".rag-index")
        sources = {chunk["source"] for chunk in chunks}
        self.assertIn("README.md", sources)
        self.assertIn("src/service.py", sources)
        self.assertNotIn(".env", sources)
        self.assertNotIn(".mcp.json", sources)
        self.assertFalse(any("should-not-be-indexed" in chunk["text"] for chunk in chunks))
        self.assertTrue((root / ".rag-index" / "manifest.json").exists())

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
        self.assertEqual({"rag_search", "rag_reindex", "rag_status", "rag_symbol", "rag_deps"}, names)

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
        self.assertEqual(manifest["num_files"], 3)

        search = subprocess.run(
            [sys.executable, str(tool), "search", "--root", str(root), "strict stop guard", "--top-k", "1"],
            check=True,
            text=True,
            capture_output=True,
        )
        results = json.loads(search.stdout)
        self.assertEqual(results[0]["source"], "README.md")

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
        self.assertEqual(manifest["num_files"], 3)


if __name__ == "__main__":
    unittest.main()
