from __future__ import annotations

import hashlib
import json
import re
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .core import extract_query_paths, resolve_root, tokenize, write_json_atomic, write_text_atomic

KNOWLEDGE_GENERATOR_VERSION = "rag.knowledge-generator.v1"
KNOWLEDGE_SUMMARY_VERSION = "rag.knowledge-summary.v1"


CATEGORY_RULES: list[tuple[str, list[str]]] = [
    ("owner_boundary", ["owner", "ownership", "boundary", "duplicate", "parallel", "deprecated", "bypass", "runtime owner"]),
    ("route_contract", ["route", "endpoint", "404", "router", "static route", "dynamic route"]),
    ("api_shape_contract", ["response.data", "data.items", "payload", "contract", "shape", "format"]),
    ("schema_form_contract", ["schemaform", "schema form", "options.params", "endpoint", "yaml", "schema"]),
    ("frontend_runtime_contract", ["vue", "store", "pinia", "spa", "component", "dropdown", "scroll", "resize"]),
    ("security_guard", ["csrf", "hmac", "command injection", "whitelist", "secret", ".env", "auth", "rbac"]),
    ("audit_contract", ["audit", "audit trail", "log", "logging"]),
    ("resource_lifecycle", ["curl_close", "file descriptors", "leak", "cleanup", "release", "lock"]),
    ("build_portability", ["bash", "macos", "declare -a", "declare -a", "set -u", "dockerfile", "dockerignore"]),
    ("rollout_control_plane", ["rollout", "node_id", "dispatcher", "update_node", "health", "rollback"]),
    ("transaction_atomicity", ["transaction", "commit", "rollback", "atomic", "lock", "claim"]),
    ("workflow_contract", ["workflow", "automation", "run_id", "step", "migrations", "dry-run"]),
    ("test_contract", ["test", "e2e", "php tests/run.php", "vitest", "playwright", "fixture"]),
]

SEVERITY_RULES: list[tuple[str, str]] = [
    ("blocker", "BLOCKER"),
    ("high", "HIGH"),
    ("medium", "MEDIUM"),
    ("low", "LOW"),
]

DEFAULT_OWNER_RULES: list[tuple[str, str, str]] = [
    ("src/", "Application Source", "main application source code"),
    ("app/", "Application Source", "main application source code"),
    ("lib/", "Library Source", "shared libraries and reusable modules"),
    ("cmd/", "CLI/Services", "commands, service entrypoints, daemons"),
    ("bin/", "CLI/Workers", "scripts, workers, validation commands"),
    ("routes/", "HTTP Routes", "route declarations and route modules"),
    ("controllers/", "HTTP Controllers", "controller contracts"),
    ("config/", "Configuration", "runtime configuration"),
    ("migrations/", "Database Migrations", "schema evolution"),
    ("database/", "Database", "database schemas, seeds, migrations"),
    ("tests/", "Tests", "unit, integration, feature, contract tests"),
    ("test/", "Tests", "unit, integration, feature, contract tests"),
    ("spec/", "Tests", "spec tests"),
    ("docs/", "Documentation", "specs, plans, guides, knowledge"),
    ("Docs/", "Documentation", "specs, plans, guides, knowledge"),
    ("plugins/", "Plugin/Extension Surface", "plugin manifests, extension code, plugin schemas"),
    ("packages/", "Packages", "workspace packages"),
    ("frontend/", "Frontend", "frontend application code"),
    ("ui/", "Frontend", "frontend application code"),
    ("web/", "Frontend", "web application code"),
    ("public/", "Public Assets", "public/static assets"),
    ("docker/", "Docker Build", "image build contracts"),
    ("Dockerfile", "Docker Build", "image build contracts"),
    (".dockerignore", "Docker Build", "build context and secret exclusion"),
]


def load_rules(path: str | Path | None) -> dict[str, Any]:
    if path is None or str(path).strip() == "":
        return {}
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else {}


def resolve_owner_rules(rules: dict[str, Any] | None = None) -> list[tuple[str, str, str]]:
    resolved = list(DEFAULT_OWNER_RULES)
    if not isinstance(rules, dict):
        return resolved
    custom = rules.get("owner_rules", [])
    custom_rows: list[tuple[str, str, str]] = []
    if isinstance(custom, list):
        for item in custom:
            if not isinstance(item, dict):
                continue
            prefix = str(item.get("prefix", "")).strip()
            owner = str(item.get("owner", "")).strip()
            scope = str(item.get("scope", "")).strip()
            if prefix and owner:
                custom_rows.append((prefix, owner, scope or "project-specific owner rule"))
    return custom_rows + resolved


def resolve_category_rules(rules: dict[str, Any] | None = None) -> list[tuple[str, list[str]]]:
    resolved = list(CATEGORY_RULES)
    if not isinstance(rules, dict):
        return resolved
    custom = rules.get("category_rules", [])
    custom_rows: list[tuple[str, list[str]]] = []
    if isinstance(custom, list):
        for item in custom:
            if not isinstance(item, dict):
                continue
            category = str(item.get("category", "")).strip()
            signals_raw = item.get("signals", [])
            signals = [str(signal).strip() for signal in signals_raw] if isinstance(signals_raw, list) else []
            signals = [signal for signal in signals if signal]
            if category and signals:
                custom_rows.append((category, signals))
    return custom_rows + resolved


def load_cases(path: str | Path) -> list[dict[str, Any]]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    return value if isinstance(value, list) else []


def file_sha256(path: str | Path | None) -> str | None:
    if path is None:
        return None
    resolved = Path(path)
    if not resolved.exists():
        return None
    return hashlib.sha256(resolved.read_bytes()).hexdigest()


def display_input_path(path: Path, metadata_root: Path | None) -> str:
    if metadata_root is not None:
        try:
            return path.relative_to(metadata_root).as_posix()
        except ValueError:
            pass
    return str(path)


def resolve_recorded_path(root: Path, value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    return path if path.is_absolute() else root / path


def infer_severity(text: str) -> str:
    lower = text.lower()
    for severity, marker in SEVERITY_RULES:
        if re.search(rf"\b{re.escape(severity)}\b", lower, re.IGNORECASE):
            return marker
    if "s-" in lower or "b-" in lower:
        return "BLOCKER"
    return "UNKNOWN"


def infer_categories(text: str, paths: list[str], category_rules: list[tuple[str, list[str]]] | None = None) -> list[str]:
    lower = text.lower()
    categories: set[str] = set()
    for category, signals in category_rules or CATEGORY_RULES:
        if any(signal.lower() in lower for signal in signals):
            categories.add(category)
    path_blob = " ".join(paths).lower()
    if "dockerfile" in path_blob or ".dockerignore" in path_blob:
        categories.add("build_portability")
    if "/schemas/" in path_blob or path_blob.endswith(".yaml"):
        categories.add("schema_form_contract")
    if "/tests/" in f"/{path_blob}" or path_blob.startswith("tests/"):
        categories.add("test_contract")
    if not categories:
        categories.add("general_review")
    return sorted(categories)


def owner_for_path(path: str, owner_rules: list[tuple[str, str, str]] | None = None) -> dict[str, str]:
    for prefix, owner, scope in owner_rules or DEFAULT_OWNER_RULES:
        if path == prefix.rstrip("/") or path.startswith(prefix):
            return {"owner": owner, "scope": scope}
    return {"owner": "Unknown", "scope": "unmapped path prefix"}


def summarize_text(text: str, limit: int = 220) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    compact = re.sub(r"^PR #\d+ review/reply evidence\.\s*", "", compact)
    marker = "Context:"
    if marker in compact:
        compact = compact.split(marker, 1)[1].strip()
    return compact[:limit].rstrip()


def normalize_case(
    case: dict[str, Any],
    owner_rules: list[tuple[str, str, str]] | None = None,
    category_rules: list[tuple[str, list[str]]] | None = None,
) -> dict[str, Any]:
    query = str(case.get("query", ""))
    expected = [str(item) for item in case.get("expected_sources", []) if str(item).strip()]
    cited = extract_query_paths(query)
    paths = []
    seen_paths: set[str] = set()
    for path in expected + cited:
        if path and path not in seen_paths:
            paths.append(path)
            seen_paths.add(path)
    owners = []
    seen_owners: set[str] = set()
    for path in paths:
        owner = owner_for_path(path, owner_rules)
        key = owner["owner"]
        if key not in seen_owners:
            owners.append(owner)
            seen_owners.add(key)
    return {
        "id": str(case.get("id", "")),
        "pr": case.get("pr"),
        "author": case.get("author"),
        "kind": case.get("kind"),
        "severity": infer_severity(query),
        "categories": infer_categories(query, paths, category_rules),
        "target_paths": expected,
        "cited_paths": cited,
        "owners": owners,
        "summary": summarize_text(query),
        "query_terms": sorted(set(tokenize(query)))[:80],
    }


def pattern_rows(lessons: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_category: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for lesson in lessons:
        for category in lesson["categories"]:
            by_category[category].append(lesson)
    rows: list[dict[str, Any]] = []
    for category, items in sorted(by_category.items(), key=lambda item: (-len(item[1]), item[0])):
        path_counter: Counter[str] = Counter()
        owner_counter: Counter[str] = Counter()
        severity_counter: Counter[str] = Counter()
        for lesson in items:
            severity_counter[str(lesson["severity"])] += 1
            for path in lesson["target_paths"]:
                path_counter[path] += 1
            for owner in lesson["owners"]:
                owner_counter[str(owner["owner"])] += 1
        rows.append(
            {
                "category": category,
                "count": len(items),
                "severities": dict(severity_counter.most_common()),
                "top_paths": [path for path, _ in path_counter.most_common(8)],
                "owners": [owner for owner, _ in owner_counter.most_common(6)],
                "example_ids": [str(item["id"]) for item in items[:5]],
            }
        )
    return rows


def owner_rows(lessons: list[dict[str, Any]], owner_rules: list[tuple[str, str, str]] | None = None) -> list[dict[str, Any]]:
    by_owner: dict[str, dict[str, Any]] = {}
    for lesson in lessons:
        for path in lesson["target_paths"] or lesson["cited_paths"]:
            owner = owner_for_path(path, owner_rules)
            name = owner["owner"]
            row = by_owner.setdefault(
                name,
                {"owner": name, "scope": owner["scope"], "count": 0, "paths": Counter(), "categories": Counter()},
            )
            row["count"] += 1
            row["paths"][path] += 1
            for category in lesson["categories"]:
                row["categories"][category] += 1
    rows: list[dict[str, Any]] = []
    for row in sorted(by_owner.values(), key=lambda item: (-int(item["count"]), str(item["owner"]))):
        rows.append(
            {
                "owner": row["owner"],
                "scope": row["scope"],
                "count": row["count"],
                "top_paths": [path for path, _ in row["paths"].most_common(10)],
                "top_categories": [category for category, _ in row["categories"].most_common(8)],
            }
        )
    return rows


def markdown_table(headers: list[str], rows: list[list[Any]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        out.append("| " + " | ".join(str(cell).replace("\n", " ") for cell in row) + " |")
    return "\n".join(out)


def render_patterns(rows: list[dict[str, Any]]) -> str:
    table_rows = [
        [
            row["category"],
            row["count"],
            ", ".join(row["owners"][:4]),
            ", ".join(row["top_paths"][:4]),
            ", ".join(row["example_ids"]),
        ]
        for row in rows
    ]
    return "# RAG Pattern Registry\n\n" + markdown_table(
        ["Category", "Cases", "Owners", "Top Paths", "Examples"],
        table_rows,
    ) + "\n"


def render_taxonomy(rows: list[dict[str, Any]]) -> str:
    parts = ["# RAG Failure Taxonomy\n"]
    for row in rows:
        parts.append(f"## {row['category']}\n")
        parts.append(f"- Cases: {row['count']}")
        parts.append(f"- Severities: {json.dumps(row['severities'], ensure_ascii=False)}")
        parts.append(f"- Owners to inspect: {', '.join(row['owners']) if row['owners'] else 'n/a'}")
        parts.append(f"- Top paths: {', '.join(row['top_paths']) if row['top_paths'] else 'n/a'}")
        parts.append(f"- Example lessons: {', '.join(row['example_ids'])}\n")
    return "\n".join(parts)


def render_owner_map(rows: list[dict[str, Any]]) -> str:
    table_rows = [
        [row["owner"], row["count"], row["scope"], ", ".join(row["top_categories"][:5]), ", ".join(row["top_paths"][:5])]
        for row in rows
    ]
    return "# RAG Owner Map\n\n" + markdown_table(
        ["Owner", "Cases", "Scope", "Top Categories", "Top Paths"],
        table_rows,
    ) + "\n"


def render_query_templates(patterns: list[dict[str, Any]]) -> str:
    parts = ["# RAG Query Templates\n"]
    parts.append("Use these templates before editing related code. Replace bracketed values with the concrete module/path.\n")
    templates = [
        ("Before module design", "owner boundary canonical spec [module] forbidden duplicate runtime --mode architecture --with-plan"),
        ("Before implementation", "[feature] controller route service store test contract --mode implementation --with-plan"),
        ("Before frontend work", "[view/component] store api client i18n route test --mode frontend --with-plan"),
        ("Before migration work", "[migration/table] schema repository rollback backfill contract test --mode migration --with-plan"),
        ("Before FDR", "[finding text] cited files [path list] --mode fdr --with-plan"),
    ]
    if patterns:
        top = patterns[0]["category"]
        templates.append((f"Top observed failure: {top}", f"{top.replace('_', ' ')} owner contract tests cited paths --mode fdr --with-plan"))
    parts.append(markdown_table(["Intent", "Search"], templates))
    parts.append("")
    return "\n".join(parts)


def write_knowledge_pack(
    cases_path: str | Path,
    out_dir_arg: str | Path,
    project_name: str = "project",
    rules_path: str | Path | None = None,
    metadata_root: str | Path | None = None,
) -> dict[str, Any]:
    cases_file = Path(cases_path).resolve()
    rules_file = Path(rules_path).resolve() if rules_path else None
    root = Path(metadata_root).resolve() if metadata_root is not None else None
    cases = load_cases(cases_file)
    rules = load_rules(rules_file)
    owner_rules = resolve_owner_rules(rules)
    category_rules = resolve_category_rules(rules)
    out_dir = Path(out_dir_arg)
    out_dir.mkdir(parents=True, exist_ok=True)
    lessons = [normalize_case(case, owner_rules, category_rules) for case in cases]
    patterns = pattern_rows(lessons)
    owners = owner_rows(lessons, owner_rules)
    lesson_lines = "".join(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n" for item in lessons)
    write_text_atomic(out_dir / "lessons.jsonl", lesson_lines)
    write_json_atomic(out_dir / "patterns.json", patterns)
    write_json_atomic(out_dir / "owner-map.json", owners)
    write_text_atomic(out_dir / "patterns.md", render_patterns(patterns))
    write_text_atomic(out_dir / "failure-taxonomy.md", render_taxonomy(patterns))
    write_text_atomic(out_dir / "owner-map.md", render_owner_map(owners))
    write_text_atomic(out_dir / "query-templates.md", render_query_templates(patterns))
    summary = {
        "schema_version": KNOWLEDGE_SUMMARY_VERSION,
        "generator_version": KNOWLEDGE_GENERATOR_VERSION,
        "generated_at": time.time(),
        "project": project_name,
        "cases": len(cases),
        "lessons": len(lessons),
        "patterns": len(patterns),
        "owners": len(owners),
        "cases_path": display_input_path(cases_file, root),
        "cases_sha256": file_sha256(cases_file),
        "rules_path": display_input_path(rules_file, root) if rules_file else None,
        "rules_sha256": file_sha256(rules_file),
        "category_rules": len(category_rules),
        "owner_rules": len(owner_rules),
        "out_dir": display_input_path(out_dir.resolve(), root),
        "artifacts": [
            "lessons.jsonl",
            "patterns.json",
            "owner-map.json",
            "patterns.md",
            "failure-taxonomy.md",
            "owner-map.md",
            "query-templates.md",
        ],
    }
    write_json_atomic(out_dir / "summary.json", summary)
    return summary


def build_project_knowledge(
    root_arg: str | Path | None,
    cases_path: str | Path,
    output: str | Path,
    project_name: str,
    rules_path: str | Path | None = None,
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    cases = Path(cases_path)
    if not cases.is_absolute():
        cases = root / cases
        if not cases.exists():
            cases = Path.cwd() / str(cases_path)
    out_path = Path(output)
    if not out_path.is_absolute():
        out_path = root / out_path
    rules = Path(rules_path) if rules_path else None
    if rules is not None and not rules.is_absolute():
        rules = root / rules
        if not rules.exists():
            rules = Path.cwd() / str(rules_path)
    return write_knowledge_pack(cases, out_path, project_name, rules, root)


def knowledge_pack_status(root_arg: str | Path | None, summary_path: str | Path) -> dict[str, Any]:
    root = resolve_root(root_arg)
    summary_file = Path(summary_path)
    if not summary_file.is_absolute():
        summary_file = root / summary_file
    if summary_file.is_dir():
        summary_file = summary_file / "summary.json"
    if not summary_file.exists():
        return {
            "exists": False,
            "summary_path": str(summary_file),
            "stale": True,
            "reason": "missing summary",
        }
    summary = json.loads(summary_file.read_text(encoding="utf-8"))
    stale_reasons: list[str] = []
    if summary.get("schema_version") != KNOWLEDGE_SUMMARY_VERSION:
        stale_reasons.append("summary schema changed")
    if summary.get("generator_version") != KNOWLEDGE_GENERATOR_VERSION:
        stale_reasons.append("generator version changed")

    cases_path = summary.get("cases_path")
    cases_file = resolve_recorded_path(root, cases_path)
    cases_current = file_sha256(cases_file)
    if cases_path and cases_current != summary.get("cases_sha256"):
        stale_reasons.append("cases file changed")
    rules_path = summary.get("rules_path")
    rules_file = resolve_recorded_path(root, rules_path)
    rules_current = file_sha256(rules_file)
    if rules_path and rules_current != summary.get("rules_sha256"):
        stale_reasons.append("rules file changed")
    return {
        "exists": True,
        "summary_path": str(summary_file),
        "stale": bool(stale_reasons),
        "reason": ", ".join(stale_reasons) if stale_reasons else None,
        "summary": summary,
        "inputs": {
            "cases_path": cases_path,
            "cases_sha256_current": cases_current,
            "rules_path": rules_path,
            "rules_sha256_current": rules_current,
        },
    }


PROFILE_CANDIDATES: list[tuple[str, str, str]] = [
    ("src/", "Application Source", "main application source code"),
    ("app/", "Application Source", "main application source code"),
    ("lib/", "Library Source", "shared libraries and reusable modules"),
    ("cmd/", "CLI/Services", "commands, service entrypoints, daemons"),
    ("bin/", "CLI/Workers", "scripts, workers, validation commands"),
    ("routes/", "HTTP Routes", "route declarations and route modules"),
    ("controllers/", "HTTP Controllers", "controller contracts"),
    ("config/", "Configuration", "runtime configuration"),
    ("migrations/", "Database Migrations", "schema evolution"),
    ("database/", "Database", "database schemas, seeds, migrations"),
    ("tests/", "Tests", "unit, integration, feature, contract tests"),
    ("test/", "Tests", "unit, integration, feature, contract tests"),
    ("spec/", "Tests", "spec tests"),
    ("docs/", "Documentation", "specs, plans, guides, knowledge"),
    ("Docs/", "Documentation", "specs, plans, guides, knowledge"),
    ("plugins/", "Plugin/Extension Surface", "plugin manifests, extension code, plugin schemas"),
    ("packages/", "Packages", "workspace packages"),
    ("frontend/", "Frontend", "frontend application code"),
    ("ui/", "Frontend", "frontend application code"),
    ("web/", "Frontend", "web application code"),
    ("public/", "Public Assets", "public/static assets"),
    ("docker/", "Docker Build", "image build contracts"),
]


def generate_project_profile(
    root_arg: str | Path | None,
    output: str | Path = "rag.knowledge.json",
    project_name: str = "project",
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    owner_rules: list[dict[str, str]] = []
    for prefix, owner, scope in PROFILE_CANDIDATES:
        candidate = root / prefix.rstrip("/")
        if candidate.exists():
            owner_rules.append({"prefix": prefix, "owner": owner, "scope": scope})
    for filename, owner, scope in [
        ("Dockerfile", "Docker Build", "image build contracts"),
        (".dockerignore", "Docker Build", "build context and secret exclusion"),
    ]:
        if (root / filename).exists():
            owner_rules.append({"prefix": filename, "owner": owner, "scope": scope})

    profile = {
        "project": project_name,
        "schema_version": "rag.knowledge-rules.v1",
        "owner_rules": owner_rules,
        "category_rules": [
            {
                "category": "project_specific_contract",
                "signals": ["contract", "canonical", "owner", "boundary"],
            }
        ],
    }
    out_path = Path(output)
    if not out_path.is_absolute():
        out_path = root / out_path
    write_json_atomic(out_path, profile)
    return {
        "project": project_name,
        "output": str(out_path),
        "owner_rules": len(owner_rules),
        "category_rules": len(profile["category_rules"]),
    }
