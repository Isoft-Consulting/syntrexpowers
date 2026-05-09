from __future__ import annotations

import copy
import fnmatch
import hashlib
import json
import math
import os
import re
import sqlite3
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

CONFIG_VERSION = "rag.config.v1"
MANIFEST_VERSION = "rag.index-manifest.v1"
CHUNK_VERSION = "rag.chunk.v1"
SYMBOL_VERSION = "rag.symbol.v1"
DEP_VERSION = "rag.dep-edge.v1"
SOURCE_STATE_VERSION = "rag.source-state.v1"
SEARCH_CACHE_VERSION = "rag.search-cache.v1"
CHUNKER_VERSION = "lexical-chunker.v1"
TOKENIZER_VERSION = "unicode-tokenizer.v1"
SEARCH_VERSION = "hash-vector-bm25.v13"

_SEARCH_CACHE_CONNECTIONS: dict[tuple[str, float, int], sqlite3.Connection] = {}

DEFAULT_CONFIG: dict[str, Any] = {
    "schema_version": CONFIG_VERSION,
    "index_dir": ".rag-index",
    "include_globs": [
        "**/*.md",
        "**/*.txt",
        "**/*.json",
        "**/*.yaml",
        "**/*.yml",
        "**/*.rb",
        "**/*.py",
        "**/*.js",
        "**/*.ts",
        "**/*.sh",
        "**/*.php",
        "Dockerfile",
        "Dockerfile.*",
        ".dockerignore",
    ],
    "force_include_globs": [
        "tests/**/*.php",
        "tests/*.php",
        "uier/tests/**/*.php",
        "uier/tests/*.php",
        "uier/public/js/*.js",
        "uier-spa/src/tests/*.js",
        "uier-spa/src/tests/*.ts",
        "uier-spa/src/tests/*.vue",
        "uier-spa/src/tests/**/*.js",
        "uier-spa/src/tests/**/*.ts",
        "uier-spa/src/tests/**/*.vue",
        "tests/Unit/*ContractTest.php",
        "tests/Unit/*ScriptTest.php",
        "tests/Unit/*Dockerfile*Test.php",
    ],
    "exclude_dirs": [
        ".git",
        ".mcp",
        ".claude",
        ".codex",
        ".agents",
        ".rag-index",
        "node_modules",
        "bower_components",
        "vendor",
        "dist",
        "build",
        "out",
        "target",
        "coverage",
        "evals",
        "storage",
        "payload",
        "sessions",
        "_tmp_storage",
        "_tmp_payload_storage",
        ".idea",
        ".vscode",
        ".next",
        ".nuxt",
        ".vite",
        ".turbo",
        ".yarn",
        ".pnpm-store",
        ".cache",
        "cache",
        "tmp",
        "temp",
        "logs",
        "__pycache__",
        ".pytest_cache",
        ".ruff_cache",
    ],
    "exclude_globs": [
        "**/*.lock",
        "**/*.map",
        "**/*.min.js",
        "**/*.min.css",
    ],
    "secret_path_patterns": [
        "**/.env",
        "**/.env.*",
        "**/.mcp.json",
        "**/*secret*",
        "**/*credential*",
        "**/*.pem",
        "**/*.key",
        "**/*.p12",
        "**/*.crt",
        "**/id_rsa",
        "**/id_ed25519",
    ],
    "max_file_bytes": 1_048_576,
    "follow_symlinks": False,
    "chunk": {
        "max_chars": 2400,
        "min_chars": 160,
        "overlap_chars": 160,
    },
    "search": {
        "hash_dim": 512,
        "min_score": 0.02,
        "docs_boost": 1.28,
        "matrix_boost": 1.12,
        "schema_boost": 1.05,
        "test_boost": 1.08,
        "code_boost": 0.55,
        "vector_weight": 0.42,
        "bm25_weight": 0.30,
        "source_weight": 0.20,
        "heading_weight": 0.08,
        "max_chunks_per_source": 1,
        "candidate_limit": 5000,
        "max_query_terms": 96,
        "explicit_path_boost": 0.75,
        "explicit_path_priority": True,
        "query_stopwords": [
            "and",
            "are",
            "but",
            "for",
            "from",
            "into",
            "not",
            "that",
            "the",
            "this",
            "with",
            "або",
            "але",
            "без",
            "був",
            "була",
            "було",
            "були",
            "для",
            "если",
            "він",
            "вона",
            "вони",
            "його",
            "йому",
            "її",
            "із",
            "или",
            "как",
            "коли",
            "має",
            "мають",
            "між",
            "над",
            "під",
            "про",
            "при",
            "так",
            "такий",
            "тому",
            "треба",
            "цей",
            "ця",
            "це",
            "цих",
            "что",
            "що",
            "щоб",
            "это",
            "як",
            "які",
            "який",
        ],
        "source_penalties": [
            {"pattern": "**/.snapshots/**", "multiplier": 0.12},
            {"pattern": "**/seeds/demo.yaml", "multiplier": 0.25},
        ],
        "status_boosts": {
            "canonical": 1.18,
            "implementation_ready": 1.14,
            "active_plan": 1.10,
            "normal": 1.0,
            "historical": 0.70,
            "superseded": 0.18,
        },
        "fdr_role_boosts": {
            "plan": 1.06,
            "spec": 1.06,
            "implementation": 1.04,
            "test": 1.08,
            "build_file": 1.08,
            "ignore_config": 1.08,
            "compose_config": 1.04,
            "config": 1.04,
            "docs": 1.0,
            "other": 1.0,
        },
        "mode_role_boosts": {
            "architecture": {
                "spec": 1.18,
                "plan": 1.12,
                "docs": 1.10,
                "implementation": 0.96,
                "test": 0.90,
                "config": 1.02,
            },
            "implementation": {
                "implementation": 1.18,
                "test": 1.12,
                "config": 1.08,
                "spec": 1.02,
                "plan": 1.02,
            },
            "frontend": {
                "implementation": 1.14,
                "test": 1.10,
                "config": 1.06,
                "spec": 1.02,
            },
            "migration": {
                "implementation": 1.12,
                "test": 1.12,
                "spec": 1.08,
                "plan": 1.06,
                "config": 1.06,
            },
            "knowledge": {
                "docs": 1.25,
                "config": 1.12,
                "spec": 1.08,
                "plan": 1.06,
                "test": 0.94,
                "implementation": 0.88,
            },
        },
        "fdr_query_expansions": {
            "autoload": ["bootstrap", "require", "include", "runtime dependency"],
            "bash": ["shell script", "macos", "posix", "set -u", "declare"],
            "dockerfile": ["dockerfile", "image", "build context", "copy", "entrypoint"],
            "dockerignore": [".dockerignore", "build context", "secrets", ".env", "storage", "dist"],
            "dry-run": ["dry_run", "--dry-run", "dry run", "exit code"],
            "migration": ["migrate", "migrations", "run_migrations", "entrypoint"],
            "rollout": ["deploy", "update", "dispatcher", "controller", "job"],
        },
        "mode_query_expansions": {
            "architecture": ["canonical", "master spec", "owner", "boundary", "forbidden", "runtime owner"],
            "implementation": ["controller", "service", "route", "store", "test", "contract"],
            "frontend": ["view", "component", "store", "api client", "i18n", "route", "test"],
            "migration": ["migration", "schema", "repository", "rollback", "backfill", "contract test"],
            "knowledge": ["knowledge", "lesson", "pattern registry", "failure taxonomy", "owner map", "query template"],
        },
        "preview_chars": 500,
        "expand_english_synonyms": False,
        "synonyms": {
            "approval": ["permission", "authorize"],
            "block": ["deny", "guard", "stop"],
            "config": ["configuration", "settings"],
            "dependency": ["deps", "import", "require"],
            "deps": ["dependency", "dependencies", "import", "require"],
            "deploy": ["install", "runtime", "enforce"],
            "enforcing": ["enforce", "enforcement", "install"],
            "fixture": ["proof", "contract", "payload"],
            "guard": ["block", "deny", "stop"],
            "hook": ["entry", "event"],
            "matrix": ["matrices"],
            "metadata": ["registry", "schema"],
            "mcp": ["mcpservers", "stdio", "tool"],
            "permission": ["approval", "deny"],
            "proof": ["fixture", "contract", "evidence"],
            "provider": ["codex", "claude", "deepseek"],
            "rag": ["retrieval", "search", "index"],
            "readiness": ["ready", "gate", "enforcing"],
            "registry": ["metadata", "schema"],
            "schema": ["registry", "contract"],
            "search": ["lookup", "retrieval", "rag"],
            "stop": ["guard", "final", "continuation"],
            "symbol": ["symbols", "lookup"],
            "tool": ["mcp", "command"],
            "готовність": ["readiness", "ready", "gate"],
            "доказ": ["proof", "evidence"],
            "докази": ["proof", "evidence"],
            "залежність": ["dependency", "deps"],
            "залежності": ["dependency", "deps"],
            "захист": ["guard", "protection"],
            "знайти": ["search", "lookup"],
            "команда": ["command", "tool"],
            "команд": ["command", "commands"],
            "небезпечна": ["destructive", "dangerous"],
            "небезпечних": ["destructive", "dangerous"],
            "пошук": ["search", "retrieval"],
            "символ": ["symbol"],
            "символи": ["symbol", "symbols"],
            "фінальна": ["final", "stop"],
            "фінальною": ["final", "stop"],
            "блокирует": ["block", "deny"],
            "готовность": ["readiness", "ready"],
            "зависимости": ["dependency", "deps"],
            "защита": ["guard", "protection"],
            "найти": ["search", "lookup"],
            "опасных": ["destructive", "dangerous"],
            "символы": ["symbol", "symbols"]
        },
    },
}

TOKEN_RE = re.compile(r"[\w./:\\-]{2,}", re.UNICODE)
SPLIT_RE = re.compile(r"[./:\\\-_]+")
CAMEL_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")


def resolve_root(root: str | os.PathLike[str] | None) -> Path:
    return Path(root or os.getcwd()).resolve()


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config(root: Path, config_path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    config = copy.deepcopy(DEFAULT_CONFIG)
    candidates: list[Path] = []
    if config_path:
        candidate = Path(config_path)
        if candidate.is_absolute():
            candidates.append(candidate)
        else:
            candidates.append(root / candidate)
            candidates.append(Path.cwd() / candidate)
    else:
        candidates.append(root / ".mcp" / "rag-server" / "rag.config.json")
        candidates.append(root / "rag.config.json")

    for candidate in candidates:
        if candidate.exists():
            with candidate.open("r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            config = deep_merge(config, loaded)
            break

    if config.get("schema_version") != CONFIG_VERSION:
        raise ValueError(f"unsupported config schema_version: {config.get('schema_version')}")
    return config


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def config_hash(config: dict[str, Any]) -> str:
    return sha256_text(canonical_json(config))


def get_index_dir(root: Path, config: dict[str, Any]) -> Path:
    configured = Path(str(config.get("index_dir", ".rag-index")))
    index_dir = configured if configured.is_absolute() else root / configured
    resolved = index_dir.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError("index_dir must resolve inside project root") from exc
    return resolved


def matches_pattern(rel_path: str, pattern: str) -> bool:
    pattern = pattern.strip()
    if not pattern:
        return False
    name = rel_path.rsplit("/", 1)[-1]
    if fnmatch.fnmatch(rel_path, pattern):
        return True
    if pattern.startswith("**/") and fnmatch.fnmatch(rel_path, pattern[3:]):
        return True
    if "/" not in pattern and fnmatch.fnmatch(name, pattern):
        return True
    return False


def matches_any(rel_path: str, patterns: list[str]) -> bool:
    return any(matches_pattern(rel_path, pattern) for pattern in patterns)


def force_include_patterns(config: dict[str, Any]) -> list[str]:
    return [str(pattern) for pattern in config.get("force_include_globs", [])]


def is_force_included(rel_path: str, config: dict[str, Any]) -> bool:
    return matches_any(rel_path, force_include_patterns(config))


def dir_has_force_include(rel_dir: str, config: dict[str, Any]) -> bool:
    rel = rel_dir.strip("/")
    if not rel:
        return bool(force_include_patterns(config))
    rel_prefix = rel + "/"
    for pattern in force_include_patterns(config):
        normalized = pattern.strip().lstrip("/")
        if normalized.startswith("**/"):
            normalized = normalized[3:]
        if normalized.startswith(rel_prefix):
            return True
    return False


def should_skip_dir(rel_dir: str, dirname: str, config: dict[str, Any]) -> bool:
    if dirname in set(config.get("exclude_dirs", [])) and not dir_has_force_include(rel_dir, config):
        return True
    if not rel_dir:
        return False
    if dir_has_force_include(rel_dir, config):
        return False
    return matches_any(rel_dir, config.get("exclude_globs", [])) or matches_any(rel_dir, config.get("secret_path_patterns", []))


def path_has_excluded_dir(rel_path: str, config: dict[str, Any]) -> bool:
    excluded = set(str(item) for item in config.get("exclude_dirs", []))
    parts = rel_path.split("/")[:-1]
    for index, part in enumerate(parts):
        prefix = "/".join(parts[: index + 1])
        if part in excluded or prefix in excluded:
            return True
    return False


def is_indexable_file(path: Path, root: Path, config: dict[str, Any]) -> bool:
    try:
        rel = path.relative_to(root).as_posix()
    except ValueError:
        return False
    if path.is_symlink() and not config.get("follow_symlinks", False):
        return False
    forced = is_force_included(rel, config)
    if not forced and not matches_any(rel, config.get("include_globs", [])):
        return False
    if path_has_excluded_dir(rel, config) and not forced:
        return False
    if matches_any(rel, config.get("exclude_globs", [])):
        return False
    if matches_any(rel, config.get("secret_path_patterns", [])):
        return False
    try:
        if path.stat().st_size > int(config.get("max_file_bytes", 1_048_576)):
            return False
    except OSError:
        return False
    return True


def iter_indexable_files(root: Path, config: dict[str, Any]) -> list[Path]:
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=bool(config.get("follow_symlinks", False))):
        current = Path(dirpath)
        try:
            rel_dir = current.relative_to(root).as_posix()
        except ValueError:
            continue

        kept_dirs = []
        for dirname in dirnames:
            child_rel = dirname if rel_dir == "." else f"{rel_dir}/{dirname}"
            if rel_dir == ".":
                child_rel = dirname
            if not should_skip_dir(child_rel, dirname, config):
                kept_dirs.append(dirname)
        dirnames[:] = kept_dirs

        for filename in filenames:
            candidate = current / filename
            if candidate.is_file() and is_indexable_file(candidate, root, config):
                files.append(candidate)
    files.sort(key=lambda item: item.relative_to(root).as_posix())
    return files


def read_text(path: Path) -> tuple[str, bytes]:
    raw = path.read_bytes()
    try:
        return raw.decode("utf-8"), raw
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace"), raw


def artifact_type(source: str, heading: str = "") -> str:
    suffix = Path(source).suffix.lower()
    lower_source = source.lower()
    lower_heading = heading.lower()
    if suffix == ".md":
        if "/spec" in lower_source or lower_source.startswith("specs/") or "spec" in lower_heading:
            return "markdown_spec"
        if "readme" in lower_source:
            return "markdown_readme"
        return "markdown_doc"
    if suffix in (".yaml", ".yml"):
        if "schema" in lower_source:
            return "yaml_schema"
        return "yaml_config"
    if suffix == ".json":
        if "schema" in lower_source or '"$schema"' in lower_heading:
            return "json_schema"
        return "json_file"
    if suffix == ".rb":
        return "ruby_file"
    if suffix == ".py":
        return "python_file"
    if suffix in (".js", ".ts"):
        return "ts_module"
    if suffix == ".sh":
        return "shell_script"
    if suffix == ".php":
        return "php_file"
    return f"{suffix.lstrip('.') or 'text'}_file"


def document_status(source: str, heading: str, text: str) -> str:
    lower_source = source.lower()
    lower_heading = heading.lower()
    sample = text[:5000].lower()
    if "superseded" in sample or "do not implement" in sample or "do not use" in sample:
        return "superseded"
    if "historical snapshot" in sample or "historical record" in sample or "frozen" in sample:
        return "historical"
    if "status:" in sample:
        if re.search(r"status:\s*(canonical|master)", sample):
            return "canonical"
        if re.search(r"status:\s*(implementation-ready|implementation ready|ready)", sample):
            return "implementation_ready"
        if re.search(r"status:\s*(active|current)", sample):
            return "active_plan"
    if "canonical / master" in sample or "canonical / implementation-ready" in sample:
        return "canonical"
    if "active plan" in sample or "active epic" in sample:
        return "active_plan"
    if "canonical" in lower_heading or "master-spec" in lower_source or "master_spec" in lower_source:
        return "canonical"
    return "normal"


def status_boost(status: str, config: dict[str, Any]) -> float:
    boosts = config.get("search", {}).get("status_boosts", {})
    if not isinstance(boosts, dict):
        return 1.0
    try:
        return float(boosts.get(status, boosts.get("normal", 1.0)))
    except (TypeError, ValueError):
        return 1.0


def read_hint(source: str, start_line: int, heading: str) -> str:
    clean_heading = re.sub(r"\s+", " ", heading).strip()
    if clean_heading and clean_heading != Path(source).name:
        return f"{source}:{start_line} ({clean_heading})"
    return f"{source}:{start_line}"


def line_for_offset(text: str, offset: int) -> int:
    return text[:offset].count("\n") + 1


def split_large_text(text: str, source: str, heading: str, start_line: int, config: dict[str, Any]) -> list[dict[str, Any]]:
    chunk_cfg = config.get("chunk", {})
    max_chars = int(chunk_cfg.get("max_chars", 2400))
    min_chars = int(chunk_cfg.get("min_chars", 160))
    overlap = min(int(chunk_cfg.get("overlap_chars", 160)), max(max_chars // 3, 0))
    chunks: list[dict[str, Any]] = []

    paragraphs = [part.strip() for part in re.split(r"\n{2,}", text) if part.strip()]
    buffer = ""
    for paragraph in paragraphs or [text.strip()]:
        if len(paragraph) > max_chars:
            if buffer:
                chunks.append(make_chunk(source, heading, buffer, start_line, len(chunks)))
                buffer = ""
            step = max(max_chars - overlap, 1)
            for idx in range(0, len(paragraph), step):
                piece = paragraph[idx : idx + max_chars].strip()
                if len(piece) >= min_chars or not chunks:
                    chunks.append(make_chunk(source, heading, piece, start_line, len(chunks)))
            continue

        candidate = f"{buffer}\n\n{paragraph}".strip() if buffer else paragraph
        if len(candidate) > max_chars and buffer:
            chunks.append(make_chunk(source, heading, buffer, start_line, len(chunks)))
            buffer = paragraph
        else:
            buffer = candidate

    if buffer and (len(buffer) >= min_chars or not chunks):
        chunks.append(make_chunk(source, heading, buffer, start_line, len(chunks)))
    return chunks


def make_chunk(source: str, heading: str, text: str, start_line: int, ordinal: int) -> dict[str, Any]:
    normalized = text.strip()
    digest = sha256_text(f"{source}\n{heading}\n{ordinal}\n{normalized}")[:16]
    status = document_status(source, heading, normalized)
    return {
        "schema_version": CHUNK_VERSION,
        "id": f"{source}:{ordinal}:{digest}",
        "source": source,
        "heading": heading,
        "artifact_type": artifact_type(source, heading),
        "document_status": status,
        "start_line": start_line,
        "text": normalized,
        "text_sha256": sha256_text(normalized),
    }


def chunk_markdown(text: str, source: str, config: dict[str, Any]) -> list[dict[str, Any]]:
    sections: list[tuple[str, int, list[str]]] = []
    heading = Path(source).name
    start_line = 1
    buffer: list[str] = []
    file_status = document_status(source, Path(source).name, text)
    for line_no, line in enumerate(text.splitlines(), start=1):
        match = HEADING_RE.match(line)
        if match and buffer:
            sections.append((heading, start_line, buffer))
            heading = match.group(2).strip()
            start_line = line_no
            buffer = [line]
        else:
            if match:
                heading = match.group(2).strip()
                start_line = line_no
            buffer.append(line)
    if buffer:
        sections.append((heading, start_line, buffer))

    chunks: list[dict[str, Any]] = []
    for section_heading, section_line, section_lines in sections:
        chunks.extend(split_large_text("\n".join(section_lines), source, section_heading, section_line, config))
    if file_status != "normal":
        for chunk in chunks:
            chunk["document_status"] = file_status
    return chunks


def chunk_file(path: Path, root: Path, config: dict[str, Any]) -> tuple[list[dict[str, Any]], str, bytes]:
    source = path.relative_to(root).as_posix()
    text, raw = read_text(path)
    if path.suffix.lower() == ".md":
        return chunk_markdown(text, source, config), text, raw
    return split_large_text(text, source, Path(source).name, 1, config), text, raw


def extract_symbols(text: str, source: str) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    suffix = Path(source).suffix.lower()

    def add(name: str, kind: str, line: int) -> None:
        clean = name.strip()
        if clean:
            symbols.append(
                {
                    "schema_version": SYMBOL_VERSION,
                    "name": clean,
                    "kind": kind,
                    "source": source,
                    "line": line,
                }
            )

    if suffix == ".md":
        for match in re.finditer(r"^(#{1,6})\s+(.+?)\s*$", text, re.MULTILINE):
            add(match.group(2), "markdown_heading", line_for_offset(text, match.start()))
    if suffix == ".json":
        for match in re.finditer(r'"\$id"\s*:\s*"([^"]+)"', text):
            add(match.group(1), "json_schema_id", line_for_offset(text, match.start()))
        for match in re.finditer(r'"title"\s*:\s*"([^"]+)"', text):
            add(match.group(1), "json_title", line_for_offset(text, match.start()))
    if suffix == ".rb":
        for match in re.finditer(r"^\s*(class|module)\s+([A-Za-z_][\w:]+)", text, re.MULTILINE):
            add(match.group(2), f"ruby_{match.group(1)}", line_for_offset(text, match.start()))
        for match in re.finditer(r"^\s*def\s+([A-Za-z_][\w!?=]*)", text, re.MULTILINE):
            add(match.group(1), "ruby_method", line_for_offset(text, match.start()))
    if suffix == ".py":
        for match in re.finditer(r"^\s*class\s+([A-Za-z_][\w]*)", text, re.MULTILINE):
            add(match.group(1), "python_class", line_for_offset(text, match.start()))
        for match in re.finditer(r"^\s*def\s+([A-Za-z_][\w]*)", text, re.MULTILINE):
            add(match.group(1), "python_function", line_for_offset(text, match.start()))
    if suffix in (".js", ".ts"):
        for match in re.finditer(r"export\s+(?:default\s+)?(?:class|function|const|interface|type)\s+([A-Za-z_][\w]*)", text):
            add(match.group(1), "ts_export", line_for_offset(text, match.start()))
    if suffix == ".php":
        for match in re.finditer(
            r"^\s*(?:(?:abstract|final|readonly)\s+)*(?:class|trait|interface|enum)\s+([A-Za-z_][\w]*)",
            text,
            re.MULTILINE,
        ):
            add(match.group(1), "php_symbol", line_for_offset(text, match.start()))
    return symbols


def extract_deps(text: str, source: str) -> list[dict[str, Any]]:
    deps: list[dict[str, Any]] = []
    suffix = Path(source).suffix.lower()

    def add(target: str, kind: str, offset: int) -> None:
        clean = target.strip()
        if clean:
            deps.append(
                {
                    "schema_version": DEP_VERSION,
                    "source": source,
                    "target": clean,
                    "kind": kind,
                    "line": line_for_offset(text, offset),
                }
            )

    patterns: list[tuple[str, str]] = []
    if suffix in (".md", ".txt"):
        seen_refs: set[str] = set()
        for match in PATH_QUERY_RE.finditer(text):
            target = match.group(0).strip("`'\"()[]{}:,;")
            while len(target) > 1 and target[-1] in ".,;:":
                target = target[:-1]
            target = target[2:] if target.startswith("./") else target
            name = target.rsplit("/", 1)[-1]
            if target == source or ("." not in name and name not in {"Dockerfile", ".dockerignore"}):
                continue
            if target not in seen_refs:
                add(target, "path_reference", match.start())
                seen_refs.add(target)
    if suffix == ".py":
        patterns.extend(
            [
                (r"^\s*import\s+([A-Za-z0-9_., \t]+)", "python_import"),
                (r"^\s*from\s+([A-Za-z0-9_.]+)\s+import\s+", "python_import"),
            ]
        )
    if suffix == ".rb":
        patterns.append((r"^\s*require(?:_relative)?\s+['\"]([^'\"]+)['\"]", "ruby_require"))
    if suffix in (".js", ".ts"):
        patterns.extend(
            [
                (r"import\s+.*?\s+from\s+['\"]([^'\"]+)['\"]", "ts_import"),
                (r"require\(\s*['\"]([^'\"]+)['\"]\s*\)", "js_require"),
            ]
        )
    if suffix == ".sh":
        patterns.append((r"^\s*(?:source|\.)\s+([A-Za-z0-9_./-]+)", "shell_source"))
    if suffix == ".php":
        patterns.append((r"^\s*use\s+([A-Za-z_\\\\][A-Za-z0-9_\\\\]+)", "php_use"))
    for pattern, kind in patterns:
        for match in re.finditer(pattern, text, re.MULTILINE):
            add(match.group(1), kind, match.start())
    return deps


def write_json_atomic(path: Path, value: Any, *, pretty: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    if pretty:
        payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    else:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    tmp.write_text(payload + "\n", encoding="utf-8")
    os.replace(tmp, path)


def write_text_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    tmp.write_text(value, encoding="utf-8")
    os.replace(tmp, path)


def summarize_source_state(entries: list[tuple[str, int, int]]) -> dict[str, Any]:
    digest = hashlib.sha256()
    for source, size, mtime_ns in sorted(entries):
        digest.update(source.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(mtime_ns).encode("ascii"))
        digest.update(b"\n")
    return {
        "schema_version": SOURCE_STATE_VERSION,
        "fingerprint": digest.hexdigest(),
        "num_files": len(entries),
    }


def scan_source_state(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    entries: list[tuple[str, int, int]] = []
    for path in iter_indexable_files(root, config):
        stat = path.stat()
        entries.append((path.relative_to(root).as_posix(), stat.st_size, stat.st_mtime_ns))
    return summarize_source_state(entries)


def close_search_cache_connections(index_dir: Path) -> None:
    index_key = str(index_dir.resolve())
    for cache_key, connection in list(_SEARCH_CACHE_CONNECTIONS.items()):
        if cache_key[0] == index_key:
            connection.close()
            _SEARCH_CACHE_CONNECTIONS.pop(cache_key, None)


def write_search_cache_sqlite(path: Path, chunks: list[dict[str, Any]], config: dict[str, Any]) -> None:
    search_cfg = config.get("search", {})
    dim = int(search_cfg.get("hash_dim", 512))
    preview_chars = int(search_cfg.get("preview_chars", 500))

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    if tmp.exists():
        tmp.unlink()

    connection = sqlite3.connect(tmp)
    try:
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.executescript(
            """
            CREATE TABLE meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            CREATE TABLE docs (
              id INTEGER PRIMARY KEY,
              source TEXT NOT NULL,
              heading TEXT NOT NULL,
              artifact_type TEXT NOT NULL,
              document_status TEXT NOT NULL,
              start_line INTEGER NOT NULL,
              preview TEXT NOT NULL,
              source_terms TEXT NOT NULL,
              heading_terms TEXT NOT NULL,
              vector TEXT NOT NULL,
              doc_length INTEGER NOT NULL
            );
            CREATE TABLE postings (
              token TEXT NOT NULL,
              doc_id INTEGER NOT NULL,
              freq INTEGER NOT NULL,
              PRIMARY KEY (token, doc_id)
            ) WITHOUT ROWID;
            """
        )

        doc_rows: list[tuple[int, str, str, str, str, int, str, str, str, str, int]] = []
        posting_rows: list[tuple[str, int, int]] = []
        total_doc_len = 0

        def flush() -> None:
            if doc_rows:
                connection.executemany(
                    "INSERT INTO docs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    doc_rows,
                )
                doc_rows.clear()
            if posting_rows:
                connection.executemany(
                    "INSERT INTO postings VALUES (?, ?, ?)",
                    posting_rows,
                )
                posting_rows.clear()

        for doc_index, chunk in enumerate(chunks):
            source = str(chunk.get("source", ""))
            heading = str(chunk.get("heading", ""))
            chunk_type = str(chunk.get("artifact_type", ""))
            doc_status = str(chunk.get("document_status", "normal"))
            text = str(chunk.get("text", ""))
            preview = re.sub(r"\s+", " ", text).strip()[:preview_chars]

            counts = token_counts(weighted_document_text(chunk))
            doc_length = sum(counts.values())
            total_doc_len += doc_length
            vector = serialize_vector(hashed_vector(counts, dim))
            doc_rows.append(
                (
                    doc_index,
                    source,
                    heading,
                    chunk_type,
                    doc_status,
                    int(chunk.get("start_line", 1)),
                    preview,
                    " ".join(sorted(set(tokenize(source)))),
                    " ".join(sorted(set(tokenize(heading)))),
                    vector,
                    doc_length,
                )
            )
            posting_rows.extend((token, doc_index, int(freq)) for token, freq in counts.items())
            if len(doc_rows) >= 500:
                flush()
        flush()

        total_docs = len(chunks)
        avg_len = total_doc_len / max(total_docs, 1)
        connection.executemany(
            "INSERT INTO meta VALUES (?, ?)",
            [
                ("schema_version", SEARCH_CACHE_VERSION),
                ("search_version", SEARCH_VERSION),
                ("hash_dim", str(dim)),
                ("total_docs", str(total_docs)),
                ("avg_len", repr(avg_len)),
            ],
        )
        connection.commit()
    finally:
        connection.close()
    os.replace(tmp, path)


def iter_indexable_file_metadata(root: Path, config: dict[str, Any]) -> list[tuple[Path, os.stat_result]]:
    items: list[tuple[Path, os.stat_result]] = []
    for path in iter_indexable_files(root, config):
        items.append((path, path.stat()))
    return items


def file_record_from_stat(source: str, raw: bytes, stat: os.stat_result, chunk_count: int) -> dict[str, Any]:
    return {
        "source": source,
        "bytes": len(raw),
        "mtime_ns": int(stat.st_mtime_ns),
        "sha256": sha256_bytes(raw),
        "chunks": chunk_count,
    }


def artifact_names() -> dict[str, str]:
    return {
        "chunks": "chunks.jsonl",
        "symbols": "symbols.json",
        "deps": "deps.json",
        "files": "files.json",
        "search_cache": "search.sqlite",
    }


def build_manifest(
    root: Path,
    config: dict[str, Any],
    files: list[dict[str, Any]],
    chunks: list[dict[str, Any]],
    symbols: list[dict[str, Any]],
    deps: list[dict[str, Any]],
    source_state_entries: list[tuple[str, int, int]],
    build_mode: str,
    changed_sources: list[str] | None = None,
    deleted_sources: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": MANIFEST_VERSION,
        "project_root": str(root),
        "indexed_at": time.time(),
        "config_hash": config_hash(config),
        "chunker_version": CHUNKER_VERSION,
        "tokenizer_version": TOKENIZER_VERSION,
        "search_version": SEARCH_VERSION,
        "num_files": len(files),
        "num_chunks": len(chunks),
        "num_symbols": len(symbols),
        "num_deps": len(deps),
        "source_state": summarize_source_state(source_state_entries),
        "artifacts": artifact_names(),
        "build_mode": build_mode,
        "change_summary": {
            "changed_sources": len(changed_sources or []),
            "deleted_sources": len(deleted_sources or []),
        },
    }


def write_index_artifacts(index_dir: Path, config: dict[str, Any], manifest: dict[str, Any], files: list[dict[str, Any]], chunks: list[dict[str, Any]], symbols: list[dict[str, Any]], deps: list[dict[str, Any]]) -> None:
    names = manifest["artifacts"]
    chunk_lines = "".join(json.dumps(chunk, ensure_ascii=False, sort_keys=True) + "\n" for chunk in chunks)
    close_search_cache_connections(index_dir)
    write_text_atomic(index_dir / str(names["chunks"]), chunk_lines)
    write_json_atomic(index_dir / str(names["symbols"]), symbols)
    write_json_atomic(index_dir / str(names["deps"]), deps)
    write_json_atomic(index_dir / str(names["files"]), files)
    write_search_cache_sqlite(index_dir / str(names["search_cache"]), chunks, config)
    legacy_search_cache = index_dir / "search-cache.json"
    if legacy_search_cache.exists():
        legacy_search_cache.unlink()
    write_json_atomic(index_dir / "manifest.json", manifest)


def build_index(root_arg: str | os.PathLike[str] | None = None, config_path: str | os.PathLike[str] | None = None, incremental: bool = False) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)

    if incremental:
        incremental_manifest = build_index_incremental(root, config, index_dir)
        if incremental_manifest is not None:
            return incremental_manifest

    chunks: list[dict[str, Any]] = []
    symbols: list[dict[str, Any]] = []
    deps: list[dict[str, Any]] = []
    files: list[dict[str, Any]] = []
    source_state_entries: list[tuple[str, int, int]] = []

    for path, stat in iter_indexable_file_metadata(root, config):
        file_chunks, text, raw = chunk_file(path, root, config)
        source = path.relative_to(root).as_posix()
        source_state_entries.append((source, stat.st_size, stat.st_mtime_ns))
        chunks.extend(file_chunks)
        symbols.extend(extract_symbols(text, source))
        deps.extend(extract_deps(text, source))
        files.append(file_record_from_stat(source, raw, stat, len(file_chunks)))

    manifest = build_manifest(root, config, files, chunks, symbols, deps, source_state_entries, "full")
    write_index_artifacts(index_dir, config, manifest, files, chunks, symbols, deps)
    return manifest


def load_manifest(index_dir: Path) -> dict[str, Any] | None:
    manifest_path = index_dir / "manifest.json"
    if not manifest_path.exists():
        return None
    with manifest_path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_chunks(index_dir: Path) -> list[dict[str, Any]]:
    chunks_path = index_dir / "chunks.jsonl"
    if not chunks_path.exists():
        return []
    chunks: list[dict[str, Any]] = []
    with chunks_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                chunks.append(json.loads(line))
    return chunks


def load_json_list(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    return value if isinstance(value, list) else []


def load_file_records(index_dir: Path) -> list[dict[str, Any]]:
    return load_json_list(index_dir / "files.json")


def incremental_rebuild_plan(root: Path, config: dict[str, Any], index_dir: Path) -> dict[str, Any] | None:
    manifest = load_manifest(index_dir)
    if manifest is None:
        return None
    if manifest.get("config_hash") != config_hash(config):
        return None
    if manifest.get("search_version") != SEARCH_VERSION:
        return None
    if manifest.get("tokenizer_version") != TOKENIZER_VERSION:
        return None
    if manifest.get("chunker_version") != CHUNKER_VERSION:
        return None

    existing_files = load_file_records(index_dir)
    if not existing_files:
        return None
    previous_by_source = {str(item.get("source", "")): item for item in existing_files if item.get("source")}
    if not previous_by_source:
        return None

    current_metadata = iter_indexable_file_metadata(root, config)
    current_by_source: dict[str, tuple[Path, os.stat_result]] = {}
    source_state_entries: list[tuple[str, int, int]] = []
    for path, stat in current_metadata:
        source = path.relative_to(root).as_posix()
        current_by_source[source] = (path, stat)
        source_state_entries.append((source, stat.st_size, stat.st_mtime_ns))

    changed_sources: list[str] = []
    changed_paths: dict[str, tuple[Path, os.stat_result]] = {}
    for source, item in current_by_source.items():
        previous = previous_by_source.get(source)
        if previous is None:
            changed_sources.append(source)
            changed_paths[source] = item
            continue
        previous_bytes = int(previous.get("bytes", -1))
        previous_mtime_ns = int(previous.get("mtime_ns", -1))
        stat = item[1]
        if previous_bytes != int(stat.st_size) or previous_mtime_ns != int(stat.st_mtime_ns):
            changed_sources.append(source)
            changed_paths[source] = item

    deleted_sources = sorted(set(previous_by_source) - set(current_by_source))
    unchanged_sources = sorted(set(current_by_source) - set(changed_sources))
    return {
        "changed_sources": sorted(changed_sources),
        "changed_paths": changed_paths,
        "deleted_sources": deleted_sources,
        "unchanged_sources": unchanged_sources,
        "source_state_entries": source_state_entries,
    }


def build_index_incremental(root: Path, config: dict[str, Any], index_dir: Path) -> dict[str, Any] | None:
    plan = incremental_rebuild_plan(root, config, index_dir)
    if plan is None:
        return None

    changed_sources = set(str(item) for item in plan["changed_sources"])
    deleted_sources = set(str(item) for item in plan["deleted_sources"])
    affected_sources = changed_sources | deleted_sources

    existing_chunks = [chunk for chunk in load_chunks(index_dir) if str(chunk.get("source", "")) not in affected_sources]
    existing_symbols = [symbol for symbol in load_json_list(index_dir / "symbols.json") if str(symbol.get("source", "")) not in affected_sources]
    existing_deps = [dep for dep in load_json_list(index_dir / "deps.json") if str(dep.get("source", "")) not in affected_sources]
    existing_files = [item for item in load_file_records(index_dir) if str(item.get("source", "")) not in affected_sources]

    new_chunks: list[dict[str, Any]] = []
    new_symbols: list[dict[str, Any]] = []
    new_deps: list[dict[str, Any]] = []
    new_files: list[dict[str, Any]] = []

    changed_paths = plan["changed_paths"]
    for source in sorted(changed_paths):
        path, stat = changed_paths[source]
        file_chunks, text, raw = chunk_file(path, root, config)
        new_chunks.extend(file_chunks)
        new_symbols.extend(extract_symbols(text, source))
        new_deps.extend(extract_deps(text, source))
        new_files.append(file_record_from_stat(source, raw, stat, len(file_chunks)))

    chunks = sorted(existing_chunks + new_chunks, key=lambda item: (str(item.get("source", "")), int(item.get("start_line", 1)), str(item.get("heading", ""))))
    symbols = sorted(existing_symbols + new_symbols, key=lambda item: (str(item.get("source", "")), int(item.get("line", 0)), str(item.get("kind", "")), str(item.get("name", ""))))
    deps = sorted(existing_deps + new_deps, key=lambda item: (str(item.get("source", "")), int(item.get("line", 0)), str(item.get("kind", "")), str(item.get("target", ""))))
    files = sorted(existing_files + new_files, key=lambda item: str(item.get("source", "")))

    manifest = build_manifest(
        root,
        config,
        files,
        chunks,
        symbols,
        deps,
        plan["source_state_entries"],
        "incremental",
        plan["changed_sources"],
        plan["deleted_sources"],
    )
    write_index_artifacts(index_dir, config, manifest, files, chunks, symbols, deps)
    return manifest


def load_search_cache(index_dir: Path) -> sqlite3.Connection | None:
    manifest = load_manifest(index_dir)
    if not manifest:
        return None
    cache_name = manifest.get("artifacts", {}).get("search_cache")
    if not isinstance(cache_name, str):
        return None
    cache_path = index_dir / cache_name
    if not cache_path.exists():
        return None
    stat = cache_path.stat()
    cache_key = (str(index_dir.resolve()), stat.st_mtime, stat.st_size)
    cached = _SEARCH_CACHE_CONNECTIONS.get(cache_key)
    if cached is not None:
        return cached

    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(f"file:{cache_path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        metadata = {str(row["key"]): str(row["value"]) for row in connection.execute("SELECT key, value FROM meta")}
    except sqlite3.DatabaseError:
        if connection is not None:
            connection.close()
        return None
    if metadata.get("schema_version") != SEARCH_CACHE_VERSION:
        connection.close()
        return None
    if metadata.get("search_version") != SEARCH_VERSION:
        connection.close()
        return None

    index_key = cache_key[0]
    for old_key, old_connection in list(_SEARCH_CACHE_CONNECTIONS.items()):
        if old_key[0] == index_key:
            old_connection.close()
            _SEARCH_CACHE_CONNECTIONS.pop(old_key, None)
    _SEARCH_CACHE_CONNECTIONS[cache_key] = connection
    return connection


def index_status(root_arg: str | os.PathLike[str] | None = None, config_path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    manifest = load_manifest(index_dir)
    expected_hash = config_hash(config)
    current_source_state = scan_source_state(root, config)
    if manifest is None:
        return {
            "exists": False,
            "index_dir": str(index_dir),
            "config_hash": expected_hash,
            "stale": True,
            "reason": "missing manifest",
            "source_state": {
                "current": current_source_state,
                "indexed": None,
            },
        }

    stale_reasons = []
    if manifest.get("config_hash") != expected_hash:
        stale_reasons.append("config hash changed")
    if manifest.get("search_version") != SEARCH_VERSION:
        stale_reasons.append("search version changed")
    if manifest.get("tokenizer_version") != TOKENIZER_VERSION:
        stale_reasons.append("tokenizer version changed")
    if manifest.get("chunker_version") != CHUNKER_VERSION:
        stale_reasons.append("chunker version changed")
    indexed_source_state = manifest.get("source_state")
    if not isinstance(indexed_source_state, dict):
        stale_reasons.append("missing source state")
    elif indexed_source_state.get("fingerprint") != current_source_state.get("fingerprint"):
        stale_reasons.append("source files changed")
    return {
        "exists": True,
        "index_dir": str(index_dir),
        "stale": bool(stale_reasons),
        "reason": ", ".join(stale_reasons) if stale_reasons else None,
        "manifest": manifest,
        "source_state": {
            "current": current_source_state,
            "indexed": indexed_source_state if isinstance(indexed_source_state, dict) else None,
        },
    }


def ensure_fresh_index(
    root_arg: str | os.PathLike[str] | None = None,
    config_path: str | os.PathLike[str] | None = None,
    auto_reindex: bool = False,
    prefer_incremental: bool = True,
) -> dict[str, Any]:
    status_before = index_status(root_arg, config_path)
    stale_before = bool(status_before.get("stale", True))
    result: dict[str, Any] = {
        "checked": True,
        "stale_before": stale_before,
        "reason_before": status_before.get("reason"),
        "reindexed": False,
        "status": status_before,
    }
    if stale_before and auto_reindex:
        manifest = build_index(root_arg, config_path, incremental=prefer_incremental)
        status_after = index_status(root_arg, config_path)
        result.update(
            {
                "reindexed": True,
                "manifest": manifest,
                "reindex_mode": manifest.get("build_mode", "full"),
                "status": status_after,
            }
        )
    return result


def watch_index(
    root_arg: str | os.PathLike[str] | None = None,
    config_path: str | os.PathLike[str] | None = None,
    interval_seconds: float = 2.0,
    debounce_seconds: float = 1.0,
    max_cycles: int | None = None,
    prefer_incremental: bool = True,
) -> dict[str, Any]:
    cycles = 0
    rebuilds = 0
    last_reason: str | None = None
    while max_cycles is None or cycles < max_cycles:
        status = index_status(root_arg, config_path)
        if not status.get("exists") or status.get("stale"):
            last_reason = str(status.get("reason") or "unknown")
            if debounce_seconds > 0:
                time.sleep(debounce_seconds)
            build_index(root_arg, config_path, incremental=prefer_incremental)
            rebuilds += 1
        cycles += 1
        if max_cycles is None and interval_seconds > 0:
            time.sleep(interval_seconds)
    return {
        "cycles": cycles,
        "rebuilds": rebuilds,
        "last_reason": last_reason,
        "status": index_status(root_arg, config_path),
    }


def resolve_coverage_path(root: Path, path: str) -> tuple[str, Path, bool]:
    candidate = Path(path)
    if candidate.is_absolute():
        resolved = candidate.resolve()
        try:
            return resolved.relative_to(root).as_posix(), resolved, True
        except ValueError:
            return path.replace("\\", "/"), resolved, False
    normalized = path[2:] if path.startswith("./") else path
    resolved = (root / normalized).resolve()
    try:
        return resolved.relative_to(root).as_posix(), resolved, True
    except ValueError:
        return normalized.replace("\\", "/"), resolved, False


def coverage_reason(path: Path, rel: str, root: Path, config: dict[str, Any]) -> str:
    if not path.exists():
        return "missing"
    if not path.is_file():
        return "not_file"
    if path.is_symlink() and not config.get("follow_symlinks", False):
        return "symlink_skipped"
    forced = is_force_included(rel, config)
    if matches_any(rel, config.get("secret_path_patterns", [])):
        return "secret_path"
    if path_has_excluded_dir(rel, config) and not forced:
        return "excluded_dir"
    if matches_any(rel, config.get("exclude_globs", [])):
        return "excluded_glob"
    if not forced and not matches_any(rel, config.get("include_globs", [])):
        return "not_in_include_globs"
    try:
        if path.stat().st_size > int(config.get("max_file_bytes", 1_048_576)):
            return "too_large"
    except OSError:
        return "stat_failed"
    return "index_stale_or_not_rebuilt"


def index_coverage(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    paths: list[str],
) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    indexed_sources = {str(item.get("source", "")) for item in load_json_list(index_dir / "files.json")}
    entries: list[dict[str, Any]] = []
    for raw_path in paths:
        rel, absolute, inside_root = resolve_coverage_path(root, str(raw_path))
        if not inside_root:
            entries.append(
                {
                    "path": str(raw_path),
                    "source": rel,
                    "exists": False,
                    "indexed": False,
                    "force_included": False,
                    "reason": "outside_root",
                }
            )
            continue
        indexed = rel in indexed_sources
        reason = "indexed" if indexed else coverage_reason(absolute, rel, root, config)
        entries.append(
            {
                "path": str(raw_path),
                "source": rel,
                "exists": absolute.exists(),
                "indexed": indexed,
                "force_included": is_force_included(rel, config),
                "reason": reason,
            }
        )
    return {
        "index_dir": str(index_dir),
        "paths": entries,
        "summary": {
            "total": len(entries),
            "indexed": sum(1 for entry in entries if entry["indexed"]),
            "not_indexed": sum(1 for entry in entries if not entry["indexed"]),
        },
    }


def tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    for raw_token in TOKEN_RE.findall(text):
        lowered = raw_token.lower()
        if len(lowered) >= 2:
            tokens.append(lowered)
        parts: list[str] = []
        for part in SPLIT_RE.split(raw_token):
            for camel_part in CAMEL_RE.split(part):
                normalized = camel_part.lower()
                if len(normalized) >= 2:
                    parts.append(normalized)
                    if normalized.endswith("ed") and len(normalized) > 4:
                        parts.append(normalized[:-1])
                        parts.append(normalized[:-2])
        tokens.extend(parts)
        if len(parts) > 1:
            tokens.append("_".join(parts))
    return tokens


def token_counts(text: str) -> Counter[str]:
    return Counter(tokenize(text))


def trim_query_counts(counts: Counter[str], config: dict[str, Any]) -> Counter[str]:
    search_cfg = config.get("search", {})
    stopwords = {str(item).lower() for item in search_cfg.get("query_stopwords", [])}
    filtered = Counter({token: count for token, count in counts.items() if token not in stopwords})
    max_terms = max(16, int(search_cfg.get("max_query_terms", 96)))
    if len(filtered) <= max_terms:
        return filtered
    ranked = sorted(filtered.items(), key=lambda item: (-item[1], -len(item[0]), item[0]))
    return Counter(dict(ranked[:max_terms]))


def expand_query(query: str, config: dict[str, Any]) -> str:
    search_cfg = config.get("search", {})
    synonyms = search_cfg.get("synonyms", {})
    if not isinstance(synonyms, dict):
        return query
    has_cyrillic = any("а" <= char.lower() <= "я" or char.lower() in "єіїґ" for char in query)
    if not has_cyrillic and not bool(search_cfg.get("expand_english_synonyms", False)):
        return query
    expansions: list[str] = []
    seen: set[str] = set()
    for token in tokenize(query):
        for synonym in synonyms.get(token, [])[:4]:
            normalized = str(synonym).strip()
            key = normalized.lower()
            if normalized and key not in seen:
                expansions.append(normalized)
                seen.add(key)
    if not expansions:
        return query
    return f"{query} {' '.join(expansions)}"


def weighted_document_text(chunk: dict[str, Any]) -> str:
    source = str(chunk.get("source", ""))
    heading = str(chunk.get("heading", ""))
    text = str(chunk.get("text", ""))
    path_words = " ".join(SPLIT_RE.split(source))
    return f"{source} {path_words} {source} {heading} {heading} {text}"


def artifact_boost(source: str, artifact: str, config: dict[str, Any]) -> float:
    search_cfg = config.get("search", {})
    if "/matrices/" in f"/{source}" or ".matrix." in source:
        return float(search_cfg.get("matrix_boost", 1.18))
    if artifact in ("json_schema", "yaml_schema") or "/schemas/" in f"/{source}":
        return float(search_cfg.get("schema_boost", 1.12))
    if artifact.startswith("markdown"):
        return float(search_cfg.get("docs_boost", 1.18))
    if "/tests/" in f"/{source}" or source.startswith("tests/"):
        return float(search_cfg.get("test_boost", 1.08))
    if artifact in ("python_file", "ruby_file", "ts_module", "php_file", "shell_script"):
        return float(search_cfg.get("code_boost", 0.9))
    return 1.0


def source_penalty(source: str, config: dict[str, Any]) -> float:
    penalty = 1.0
    for item in config.get("search", {}).get("source_penalties", []):
        if not isinstance(item, dict):
            continue
        pattern = str(item.get("pattern", "")).strip()
        if not pattern or not matches_pattern(source, pattern):
            continue
        try:
            multiplier = max(0.0, min(float(item.get("multiplier", 1.0)), 1.0))
        except (TypeError, ValueError):
            continue
        penalty *= multiplier
    return penalty


def normalize_search_mode(mode: str | None) -> str:
    normalized = str(mode or "default").strip().lower()
    if normalized in ("fdr", "review"):
        return "fdr"
    if normalized in ("architecture", "arch", "design"):
        return "architecture"
    if normalized in ("implementation", "implement", "code"):
        return "implementation"
    if normalized in ("frontend", "ui", "spa"):
        return "frontend"
    if normalized in ("migration", "migrations", "schema"):
        return "migration"
    if normalized in ("knowledge", "lessons", "patterns", "taxonomy"):
        return "knowledge"
    return "default"


def mode_source_boost(source: str, config: dict[str, Any], mode: str) -> float:
    if normalize_search_mode(mode) != "knowledge":
        return 1.0
    lower = source.lower()
    if lower.startswith(".mcp/rag-server/knowledge/"):
        return 2.2
    if lower.startswith("docs/knowledge/rag/"):
        return 2.0
    if lower.startswith("knowledge/") or "/knowledge/" in f"/{lower}":
        return 1.6
    if lower.startswith("docs/knowledge/"):
        return 1.6
    if lower.endswith(("patterns.md", "failure-taxonomy.md", "owner-map.md", "query-templates.md", "lessons.jsonl")):
        return 1.35
    return 1.0


def is_local_rag_source(source: str) -> bool:
    return source.lower().startswith(".mcp/rag-server/")


def is_curated_knowledge_source(source: str) -> bool:
    lower = source.lower()
    if lower.startswith(".mcp/rag-server/knowledge/"):
        return True
    if lower.startswith("docs/knowledge/rag/"):
        return True
    if lower.startswith("knowledge/"):
        return True
    if lower.endswith(("patterns.md", "failure-taxonomy.md", "owner-map.md", "query-templates.md", "lessons.jsonl", "summary.json")):
        return True
    return False


def is_policy_or_operator_doc(source: str) -> bool:
    lower = source.lower()
    name = Path(source).name.lower()
    if name in {"agents.md", "claude.md", "agents-plugins.md"}:
        return True
    return lower.startswith("docs/collective-memory/") or lower.startswith("docs/ops/")


REVIEW_COMMENT_MARKERS = {
    "actual",
    "bug",
    "error",
    "expected",
    "fail",
    "failure",
    "finding",
    "harm",
    "line",
    "reality",
    "repro",
    "severity",
    "truncate",
    "truncation",
    "unbound",
    "utf8",
    "utf8mb4",
}


def extract_review_comment_terms(query: str) -> list[str]:
    identifiers: list[str] = []
    seen: set[str] = set()
    for match in re.finditer(r"\b[A-Za-z][A-Za-z0-9_]{2,}\b", query):
        normalized = match.group(0).lower()
        if "_" not in normalized:
            continue
        if normalized not in seen:
            identifiers.append(normalized)
            seen.add(normalized)
    for token in tokenize(query):
        normalized = token.strip("_-")
        if len(normalized) < 3:
            continue
        if normalized.isdigit():
            continue
        if normalized.count("_") > 2 and len(normalized) > 24:
            continue
        if normalized in seen:
            continue
        if "_" in normalized or any(char.isdigit() for char in normalized):
            identifiers.append(normalized)
            seen.add(normalized)
            continue
        if normalized in {"strlen", "substr", "mb_strlen", "mb_substr", "utf8mb4", "dockerfile", "dockerignore", "autoload"}:
            identifiers.append(normalized)
            seen.add(normalized)
    for path in extract_query_paths(query):
        basename = Path(path).name.lower()
        if basename and basename not in seen:
            identifiers.append(basename)
            seen.add(basename)
    return identifiers[:10]


def score_query_profile(query: str, mode: str, filter_source: str | None = None) -> dict[str, Any]:
    normalized_mode = normalize_search_mode(mode)
    query_terms = set(tokenize(query))
    lower_query = query.lower()
    explicit_paths = extract_query_paths(query)
    review_terms = extract_review_comment_terms(query)
    self_rag_terms = {
        "rag",
        "retrieval",
        "bm25",
        "vector",
        "chunk",
        "chunking",
        "ranking",
        "rerank",
        "search",
        "index",
        "indexing",
        "knowledge-build",
        "quality-check",
        "eval-quality",
        "token",
        "tokens",
        "latency",
        "candidate",
        "candidates",
        "sqlite",
    }
    knowledge_terms = {
        "knowledge",
        "lesson",
        "lessons",
        "pattern",
        "patterns",
        "taxonomy",
        "owner",
        "owners",
        "template",
        "templates",
    }
    broad = len(query_terms) >= 6 and not explicit_paths
    filter_text = (filter_source or "").lower()
    self_rag = (
        ".mcp/rag-server" in filter_text
        or any(term in query_terms for term in self_rag_terms)
        or ".mcp/rag-server" in lower_query
    )
    knowledge_intent = normalized_mode == "knowledge" or any(term in query_terms for term in knowledge_terms)
    broad_implementation = broad and normalized_mode in {"default", "implementation"} and not explicit_paths
    self_rag_code_intent = self_rag and normalized_mode == "implementation"
    review_marker_hits = sum(1 for marker in REVIEW_COMMENT_MARKERS if marker in query_terms)
    review_comment = (
        normalized_mode in {"default", "implementation", "fdr"}
        and len(query_terms) >= 8
        and (review_marker_hits >= 2 or len(review_terms) >= 2 or "line " in lower_query)
    )
    return {
        "mode": normalized_mode,
        "explicit_paths": explicit_paths,
        "broad": broad,
        "self_rag": self_rag,
        "knowledge_intent": knowledge_intent,
        "broad_implementation": broad_implementation,
        "self_rag_code_intent": self_rag_code_intent,
        "review_comment": review_comment,
        "review_terms": review_terms,
        "filter_source": filter_source or "",
    }


def adaptive_candidate_limit(base_limit: int, profile: dict[str, Any]) -> int:
    if profile["review_comment"]:
        return max(300, min(base_limit, 1800))
    if profile["self_rag"]:
        return max(250, min(base_limit, 1500))
    if profile["knowledge_intent"]:
        return max(300, min(base_limit, 2000))
    if profile["broad_implementation"]:
        return max(400, min(base_limit, 2500))
    return base_limit


def adaptive_max_chunks_per_source(base_limit: int, profile: dict[str, Any]) -> int:
    if profile["review_comment"] or profile["broad"] or profile["knowledge_intent"]:
        return 1
    return base_limit


def adaptive_read_plan_limit(profile: dict[str, Any], default_limit: int = 6) -> int:
    if profile["review_comment"]:
        return min(default_limit, 4)
    if profile["self_rag"] or profile["knowledge_intent"]:
        return min(default_limit, 4)
    if profile["broad_implementation"]:
        return min(default_limit, 5)
    return default_limit


def intent_source_multiplier(source: str, artifact: str, role: str, profile: dict[str, Any]) -> float:
    multiplier = 1.0
    if profile["filter_source"] and profile["filter_source"] in source:
        multiplier *= 1.35
    if profile["self_rag"]:
        if is_local_rag_source(source):
            multiplier *= 2.4
            lower = source.lower()
            if "/rag_universal/" in lower:
                multiplier *= 1.55
            elif role == "config":
                multiplier *= 1.18
            elif role == "docs":
                multiplier *= 1.1
            elif role == "test":
                multiplier *= 0.78
        elif is_policy_or_operator_doc(source):
            multiplier *= 0.42
    if profile["self_rag_code_intent"]:
        lower = source.lower()
        if "/rag_universal/" in lower:
            if role == "implementation":
                multiplier *= 1.95
            elif role == "test":
                multiplier *= 0.52
        elif "/knowledge/" in lower:
            multiplier *= 0.34
        elif role == "config":
            multiplier *= 0.72
    if profile["knowledge_intent"]:
        if profile["self_rag_code_intent"] and is_local_rag_source(source):
            if "/knowledge/" in source.lower():
                multiplier *= 0.58
            elif role == "implementation":
                multiplier *= 1.2
            elif role == "config":
                multiplier *= 0.92
            return multiplier
        if is_curated_knowledge_source(source):
            multiplier *= 1.9
        elif artifact.startswith("markdown"):
            multiplier *= 0.62
        else:
            multiplier *= 0.82
    if profile["broad_implementation"]:
        if is_policy_or_operator_doc(source):
            multiplier *= 0.22
        elif role == "docs":
            multiplier *= 0.52
        elif role in {"plan", "spec"}:
            multiplier *= 0.72
        elif role == "test":
            multiplier *= 0.92
        elif role in {"implementation", "config"}:
            multiplier *= 1.14
    if profile["review_comment"]:
        if role in {"implementation", "build_file", "ignore_config", "compose_config"}:
            multiplier *= 1.28
        elif role == "test":
            multiplier *= 1.04
        elif role in {"docs", "plan", "spec"}:
            multiplier *= 0.62
        elif role == "config":
            multiplier *= 0.84
        if is_policy_or_operator_doc(source):
            multiplier *= 0.18
    return multiplier


def review_term_overlap(profile: dict[str, Any], source: str, heading: str, preview: str) -> float:
    if not profile.get("review_comment"):
        return 0.0
    terms = [str(term).lower() for term in profile.get("review_terms", []) if str(term).strip()]
    if not terms:
        return 0.0
    source_lower = source.lower()
    heading_lower = heading.lower()
    preview_lower = preview.lower()
    weighted_matches = 0.0
    for term in terms:
        if term in source_lower:
            weighted_matches += 1.6
            continue
        if term in heading_lower:
            weighted_matches += 1.15
            continue
        if term in preview_lower:
            weighted_matches += 1.0
    return weighted_matches / (len(terms) * 1.6)


def review_term_multiplier(profile: dict[str, Any], source: str, heading: str, preview: str) -> float:
    overlap = review_term_overlap(profile, source, heading, preview)
    if overlap <= 0.0:
        return 1.0
    lower = source.lower()
    if lower.endswith(".dockerignore") or Path(source).name.lower().startswith("dockerfile"):
        return 1.18 + min(0.28, overlap * 0.35)
    if lower.endswith((".sh", ".php", ".py")):
        return 1.12 + min(0.34, overlap * 0.42)
    return 1.06 + min(0.22, overlap * 0.30)


def fdr_role(source: str, artifact: str) -> str:
    lower = source.lower()
    wrapped = f"/{lower}"
    name = Path(source).name.lower()
    if lower.startswith("tests/") or "/tests/" in wrapped:
        return "test"
    if name == ".dockerignore":
        return "ignore_config"
    if name == "dockerfile" or name.startswith("dockerfile."):
        return "build_file"
    if "docker-compose" in name or name in ("compose.yaml", "compose.yml"):
        return "compose_config"
    if "/docs/plans/" in wrapped or lower.startswith("plans/"):
        return "plan"
    if "/docs/specs/" in wrapped or lower.startswith("specs/") or artifact == "markdown_spec":
        return "spec"
    if artifact in ("python_file", "ruby_file", "ts_module", "php_file", "shell_script"):
        return "implementation"
    if artifact in ("json_file", "json_schema", "yaml_config", "yaml_schema"):
        return "config"
    if artifact.startswith("markdown"):
        return "docs"
    return "other"


def fdr_role_boost(source: str, artifact: str, config: dict[str, Any], mode: str) -> float:
    role = fdr_role(source, artifact)
    search_mode = normalize_search_mode(mode)
    if search_mode == "fdr":
        boosts = config.get("search", {}).get("fdr_role_boosts", {})
    else:
        mode_boosts = config.get("search", {}).get("mode_role_boosts", {})
        boosts = mode_boosts.get(search_mode, {}) if isinstance(mode_boosts, dict) else {}
    if not isinstance(boosts, dict):
        return 1.0
    try:
        return float(boosts.get(role, 1.0))
    except (TypeError, ValueError):
        return 1.0


def expand_for_search_mode(query: str, config: dict[str, Any], mode: str) -> str:
    expanded = expand_query(query, config)
    search_mode = normalize_search_mode(mode)
    mode_expansions = config.get("search", {}).get("mode_query_expansions", {})
    if isinstance(mode_expansions, dict):
        values = mode_expansions.get(search_mode, [])
        additions: list[str] = []
        seen = {term.lower() for term in tokenize(expanded)}
        for value in values if isinstance(values, list) else [values]:
            normalized = str(value).strip()
            key = normalized.lower()
            if normalized and key not in seen:
                additions.append(normalized)
                seen.add(key)
        if additions:
            expanded = f"{expanded} {' '.join(additions)}"

    if search_mode != "fdr":
        return expanded
    expansions_cfg = config.get("search", {}).get("fdr_query_expansions", {})
    if not isinstance(expansions_cfg, dict):
        return expanded
    lower_query = query.lower()
    query_terms = set(tokenize(query))
    additions: list[str] = []
    seen = {term.lower() for term in tokenize(expanded)}
    for trigger, terms in expansions_cfg.items():
        trigger_text = str(trigger).lower()
        trigger_terms = set(tokenize(trigger_text))
        if trigger_text not in lower_query and not (trigger_terms and trigger_terms <= query_terms):
            continue
        values = terms if isinstance(terms, list) else [terms]
        for value in values[:8]:
            normalized = str(value).strip()
            key = normalized.lower()
            if normalized and key not in seen:
                additions.append(normalized)
                seen.add(key)
    if not additions:
        return expanded
    return f"{expanded} {' '.join(additions)}"


def overlap_score(query_terms: set[str], text: str) -> float:
    if not query_terms:
        return 0.0
    terms = set(tokenize(text))
    if not terms:
        return 0.0
    return len(query_terms & terms) / len(query_terms)


def hashed_vector(counts: Counter[str], dim: int) -> dict[int, float]:
    vector: dict[int, float] = defaultdict(float)
    for token, count in counts.items():
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        bucket = int.from_bytes(digest[:4], "big") % dim
        sign = 1.0 if digest[4] % 2 else -1.0
        vector[bucket] += sign * (1.0 + math.log(count))
    norm = math.sqrt(sum(value * value for value in vector.values()))
    if norm == 0:
        return {}
    return {key: value / norm for key, value in vector.items()}


def serialize_vector(vector: dict[int, float]) -> str:
    return " ".join(f"{bucket}:{value:.8g}" for bucket, value in sorted(vector.items()))


def cosine_serialized(query_vector: dict[int, float], encoded_vector: str) -> float:
    if not query_vector or not encoded_vector:
        return 0.0
    score = 0.0
    for item in encoded_vector.split():
        bucket_text, _, value_text = item.partition(":")
        if not bucket_text or not value_text:
            continue
        score += query_vector.get(int(bucket_text), 0.0) * float(value_text)
    return score


def cosine_sparse(left: dict[int, float], right: dict[int, float]) -> float:
    if not left or not right:
        return 0.0
    if len(left) > len(right):
        left, right = right, left
    return sum(value * right.get(key, 0.0) for key, value in left.items())


def bm25_scores(query_counts: Counter[str], doc_counts: list[Counter[str]]) -> list[float]:
    if not doc_counts:
        return []
    total_docs = len(doc_counts)
    doc_lengths = [sum(counts.values()) for counts in doc_counts]
    avg_len = sum(doc_lengths) / max(total_docs, 1)
    df: Counter[str] = Counter()
    for counts in doc_counts:
        for token in counts:
            df[token] += 1

    scores: list[float] = []
    k1 = 1.5
    b = 0.75
    for counts, doc_len in zip(doc_counts, doc_lengths):
        score = 0.0
        for token in query_counts:
            freq = counts.get(token, 0)
            if freq == 0:
                continue
            idf = math.log((total_docs - df[token] + 0.5) / (df[token] + 0.5) + 1.0)
            denom = freq + k1 * (1.0 - b + b * doc_len / max(avg_len, 1.0))
            score += idf * (freq * (k1 + 1.0)) / max(denom, 0.001)
        scores.append(score)
    return scores


def overlap_terms(query_terms: set[str], terms: Any) -> float:
    if not query_terms:
        return 0.0
    if isinstance(terms, str):
        term_set = set(terms.split())
    elif isinstance(terms, list):
        term_set = set(str(term) for term in terms)
    else:
        return 0.0
    return len(query_terms & term_set) / len(query_terms)


PATH_QUERY_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])(?:\.?[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+"
    r"|(?<![A-Za-z0-9_./-])(?:Dockerfile(?:\\.[A-Za-z0-9_.-]+)?|docker-compose\\.(?:ya?ml)|\\.dockerignore)(?![A-Za-z0-9_./-])"
    r"|(?<!\\S)\\.[A-Za-z0-9_.-]+"
)


def extract_query_paths(query: str) -> list[str]:
    paths: list[str] = []
    seen: set[str] = set()
    special_names = {"dockerfile", ".dockerignore", "docker-compose.yml", "docker-compose.yaml"}
    for raw in query.split():
        candidate = raw.strip("`'\"()[]{}:,;")
        lowered = candidate.lower()
        if lowered in special_names or lowered.startswith("dockerfile."):
            if candidate not in seen:
                paths.append(candidate)
                seen.add(candidate)
    for match in PATH_QUERY_RE.finditer(query):
        candidate = match.group(0).strip("`'\"()[]{}:,;")
        while len(candidate) > 1 and candidate[-1] in ".,;:":
            candidate = candidate[:-1]
        if not candidate:
            continue
        normalized = candidate[2:] if candidate.startswith("./") else candidate
        name = normalized.rsplit("/", 1)[-1]
        if "." not in name and name.lower() not in special_names:
            continue
        if normalized not in seen:
            paths.append(normalized)
            seen.add(normalized)
    return paths


def escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def fetch_path_candidates(connection: sqlite3.Connection, query_paths: list[str]) -> dict[int, float]:
    matches: dict[int, float] = {}
    for order, path in enumerate(query_paths):
        if not path:
            continue
        exact_score = max(0.9, 1.0 - order * 0.01)
        suffix_score = max(0.75, 0.85 - order * 0.01)
        exact_rows = connection.execute("SELECT id FROM docs WHERE source = ? ORDER BY start_line LIMIT 1", (path,)).fetchall()
        for row in exact_rows:
            matches[int(row["id"])] = max(matches.get(int(row["id"]), 0.0), exact_score)
        if exact_rows:
            continue
        suffix = "%/" + escape_like(path)
        for row in connection.execute("SELECT MIN(id) AS id FROM docs WHERE source LIKE ? ESCAPE '\\' GROUP BY source", (suffix,)):
            matches[int(row["id"])] = max(matches.get(int(row["id"]), 0.0), suffix_score)
    return matches


def search_sort_key(item: dict[str, Any], config: dict[str, Any]) -> tuple[float, float, str, int]:
    path_priority = bool(config.get("search", {}).get("explicit_path_priority", True))
    path_match = float(item.get("path_match", 0.0)) if path_priority else 0.0
    return (-path_match, -float(item["score"]), str(item["source"]), int(item["start_line"]))


def self_rag_role_rank(source: str, role: str, profile: dict[str, Any]) -> int:
    if not profile.get("self_rag_code_intent"):
        return 99
    lower = source.lower()
    if "/rag_universal/" in lower and role == "implementation":
        return 0
    if lower.endswith("/mcp_server.py") and role == "implementation":
        return 1
    if lower.endswith("/eval_quality.py") and role == "implementation":
        return 1
    if role == "implementation":
        return 2
    if role == "config" and "/knowledge/" not in lower:
        return 3
    if role == "docs" and "/knowledge/" not in lower:
        return 4
    if role == "config":
        return 5
    if role == "docs":
        return 6
    if role == "test":
        return 7
    return 8


def review_comment_role_rank(source: str, role: str, profile: dict[str, Any]) -> int:
    if not profile.get("review_comment"):
        return 99
    lower = source.lower()
    name = Path(source).name.lower()
    if role == "implementation":
        return 0
    if role in {"build_file", "ignore_config", "compose_config"}:
        return 1
    if name in {".dockerignore", "dockerfile", "dockerfile.core-api", "dockerfile.uier-api", "dockerfile.uier-spa"}:
        return 1
    if role == "config":
        return 2
    if role == "test":
        return 3
    if role in {"plan", "spec", "docs"}:
        return 4
    if is_policy_or_operator_doc(lower):
        return 5
    return 6


def profile_result_sort_key(item: dict[str, Any], config: dict[str, Any], profile: dict[str, Any]) -> tuple[float, float, float, str, int]:
    if profile.get("self_rag_code_intent"):
        role_rank = self_rag_role_rank(str(item.get("source", "")), str(item.get("fdr_role", "other")), profile)
        path_priority = bool(config.get("search", {}).get("explicit_path_priority", True))
        path_match = float(item.get("path_match", 0.0)) if path_priority else 0.0
        return (float(role_rank), -path_match, -float(item["score"]), str(item["source"]), int(item["start_line"]))
    if profile.get("review_comment"):
        role_rank = review_comment_role_rank(str(item.get("source", "")), str(item.get("fdr_role", "other")), profile)
        path_priority = bool(config.get("search", {}).get("explicit_path_priority", True))
        path_match = float(item.get("path_match", 0.0)) if path_priority else 0.0
        return (float(role_rank), -path_match, -float(item["score"]), str(item["source"]), int(item["start_line"]))
    default_key = search_sort_key(item, config)
    return (0.0, *default_key)


def fetch_cached_docs(connection: sqlite3.Connection, doc_ids: set[int]) -> dict[int, sqlite3.Row]:
    docs: dict[int, sqlite3.Row] = {}
    ordered_ids = sorted(doc_ids)
    for offset in range(0, len(ordered_ids), 800):
        batch = ordered_ids[offset : offset + 800]
        placeholders = ",".join("?" for _ in batch)
        query = (
            "SELECT id, source, heading, artifact_type, document_status, start_line, preview, source_terms, heading_terms, vector "
            f"FROM docs WHERE id IN ({placeholders})"
        )
        for row in connection.execute(query, batch):
            docs[int(row["id"])] = row
    return docs


def rows_to_results(
    rows: list[sqlite3.Row],
    config: dict[str, Any],
    path_matches: dict[int, float],
    mode: str,
    profile: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    active_profile = profile or score_query_profile("", mode, None)
    for row in rows:
        source = str(row["source"] or "")
        chunk_type = str(row["artifact_type"] or "")
        doc_status = str(row["document_status"] or "normal")
        start_line = int(row["start_line"] or 1)
        path_match = path_matches.get(int(row["id"]), 0.0)
        penalty = source_penalty(source, config)
        doc_status_boost = status_boost(doc_status, config)
        role = fdr_role(source, chunk_type)
        intent_multiplier = intent_source_multiplier(source, chunk_type, role, active_profile)
        review_multiplier = review_term_multiplier(active_profile, source, str(row["heading"] or ""), str(row["preview"] or ""))
        score = (
            float(config.get("search", {}).get("explicit_path_boost", 0.75)) * path_match
            * artifact_boost(source, chunk_type, config)
            * fdr_role_boost(source, chunk_type, config, mode)
            * mode_source_boost(source, config, mode)
            * penalty
            * doc_status_boost
            * intent_multiplier
            * review_multiplier
        )
        results.append(
            {
                "score": round(score, 6),
                "vector": 0.0,
                "bm25": 0.0,
                "source_match": 0.0,
                "heading_match": 0.0,
                "path_match": round(path_match, 6),
                "source_penalty": round(penalty, 6),
                "status_boost": round(doc_status_boost, 6),
                "intent_boost": round(intent_multiplier, 6),
                "review_boost": round(review_multiplier, 6),
                "fdr_role": role,
                "source": source,
                "heading": row["heading"] or "",
                "section": row["heading"] or "",
                "artifact_type": chunk_type,
                "document_status": doc_status,
                "start_line": start_line,
                "read_hint": read_hint(source, start_line, str(row["heading"] or "")),
                "preview": row["preview"] or "",
            }
        )
    results.sort(key=lambda item: search_sort_key(item, config))
    return results


def search_precomputed_cache(
    connection: sqlite3.Connection,
    config: dict[str, Any],
    query: str,
    top_k: int = 5,
    filter_source: str | None = None,
    filter_type: str | None = None,
    mode: str = "default",
) -> list[dict[str, Any]]:
    metadata = {str(row["key"]): str(row["value"]) for row in connection.execute("SELECT key, value FROM meta")}
    search_cfg = config.get("search", {})
    dim = int(search_cfg.get("hash_dim", int(metadata.get("hash_dim", 512))))
    min_score = float(search_cfg.get("min_score", 0.02))
    vector_weight = float(search_cfg.get("vector_weight", 0.45))
    bm25_weight = float(search_cfg.get("bm25_weight", 0.35))
    source_weight = float(search_cfg.get("source_weight", 0.14))
    heading_weight = float(search_cfg.get("heading_weight", 0.06))
    base_max_chunks_per_source = max(1, int(search_cfg.get("max_chunks_per_source", 2)))
    base_candidate_limit = max(50, int(search_cfg.get("candidate_limit", 5000)))
    explicit_path_boost = float(search_cfg.get("explicit_path_boost", 0.75))

    search_mode = normalize_search_mode(mode)
    profile = score_query_profile(query, search_mode, filter_source)
    max_chunks_per_source = adaptive_max_chunks_per_source(base_max_chunks_per_source, profile)
    candidate_limit = adaptive_candidate_limit(base_candidate_limit, profile)
    expanded_query = expand_for_search_mode(query, config, search_mode)
    query_counts = trim_query_counts(token_counts(expanded_query), config)
    query_terms = set(query_counts)
    query_vector = hashed_vector(query_counts, dim)
    path_matches = fetch_path_candidates(connection, extract_query_paths(query))
    if path_matches and bool(search_cfg.get("explicit_path_priority", True)):
        path_docs = fetch_cached_docs(connection, set(path_matches))
        path_results = rows_to_results(list(path_docs.values()), config, path_matches, search_mode, profile)
        if path_results:
            return select_search_results(path_results, top_k, max_chunks_per_source, "default", config, profile)

    total_docs = int(metadata.get("total_docs", 0))
    avg_len = float(metadata.get("avg_len", 1.0))
    raw_bm25_by_doc: dict[int, float] = defaultdict(float)
    k1 = 1.5
    b = 0.75
    for token in query_counts:
        token_rows = list(
            connection.execute(
                """
                SELECT postings.doc_id, postings.freq, docs.doc_length
                FROM postings
                JOIN docs ON docs.id = postings.doc_id
                WHERE postings.token = ?
                """,
                (token,),
            )
        )
        if not token_rows:
            continue
        df = len(token_rows)
        idf = math.log((total_docs - df + 0.5) / (df + 0.5) + 1.0)
        for row in token_rows:
            doc_index = int(row["doc_id"])
            freq = int(row["freq"])
            doc_len = int(row["doc_length"])
            denom = freq + k1 * (1.0 - b + b * doc_len / max(avg_len, 1.0))
            raw_bm25_by_doc[doc_index] += idf * (freq * (k1 + 1.0)) / max(denom, 0.001)

    max_bm25 = max(raw_bm25_by_doc.values()) if raw_bm25_by_doc else 0.0
    if filter_source:
        candidate_indexes = set(raw_bm25_by_doc)
    else:
        ranked_candidates = sorted(raw_bm25_by_doc, key=lambda item: raw_bm25_by_doc[item], reverse=True)
        candidate_indexes = set(ranked_candidates[:candidate_limit])
    candidate_indexes.update(path_matches)
    docs_by_id = fetch_cached_docs(connection, candidate_indexes)

    results: list[dict[str, Any]] = []
    for index in candidate_indexes:
        doc = docs_by_id.get(index)
        if doc is None:
            continue
        source = str(doc["source"] or "")
        chunk_type = str(doc["artifact_type"] or "")
        doc_status = str(doc["document_status"] or "normal")
        if filter_source and filter_source not in source:
            continue
        if filter_type and not chunk_type.startswith(filter_type):
            continue
        vector_score = max(cosine_serialized(query_vector, str(doc["vector"] or "")), 0.0)
        bm25 = raw_bm25_by_doc.get(index, 0.0) / max_bm25 if max_bm25 > 0 else 0.0
        source_match = overlap_terms(query_terms, doc["source_terms"])
        heading_match = overlap_terms(query_terms, doc["heading_terms"])
        path_match = path_matches.get(index, 0.0)
        score = (
            vector_weight * vector_score
            + bm25_weight * bm25
            + source_weight * source_match
            + heading_weight * heading_match
            + explicit_path_boost * path_match
        )
        penalty = source_penalty(source, config)
        doc_status_boost = status_boost(doc_status, config)
        role = fdr_role(source, chunk_type)
        intent_multiplier = intent_source_multiplier(source, chunk_type, role, profile)
        review_multiplier = review_term_multiplier(profile, source, str(doc["heading"] or ""), str(doc["preview"] or ""))
        score *= artifact_boost(source, chunk_type, config)
        score *= fdr_role_boost(source, chunk_type, config, search_mode)
        score *= mode_source_boost(source, config, search_mode)
        score *= penalty
        score *= doc_status_boost
        score *= intent_multiplier
        score *= review_multiplier
        if score < min_score:
            continue
        start_line = int(doc["start_line"] or 1)
        results.append(
            {
                "score": round(score, 6),
                "vector": round(vector_score, 6),
                "bm25": round(bm25, 6),
                "source_match": round(source_match, 6),
                "heading_match": round(heading_match, 6),
                "path_match": round(path_match, 6),
                "source_penalty": round(penalty, 6),
                "status_boost": round(doc_status_boost, 6),
                "intent_boost": round(intent_multiplier, 6),
                "review_boost": round(review_multiplier, 6),
                "fdr_role": role,
                "source": source,
                "heading": doc["heading"] or "",
                "section": doc["heading"] or "",
                "artifact_type": chunk_type,
                "document_status": doc_status,
                "start_line": start_line,
                "read_hint": read_hint(source, start_line, str(doc["heading"] or "")),
                "preview": doc["preview"] or "",
            }
        )

    results.sort(key=lambda item: search_sort_key(item, config))
    return select_search_results(results, top_k, max_chunks_per_source, search_mode, config, profile)


def select_search_results(
    results: list[dict[str, Any]],
    top_k: int,
    max_chunks_per_source: int,
    mode: str,
    config: dict[str, Any] | None = None,
    profile: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    limit = max(1, min(int(top_k), 50))
    selected: list[dict[str, Any]] = []
    source_counts: Counter[str] = Counter()
    selected_keys: set[tuple[str, int, str]] = set()
    active_config = config or DEFAULT_CONFIG
    active_profile = profile or score_query_profile("", mode, None)
    ordered_results = sorted(results, key=lambda item: profile_result_sort_key(item, active_config, active_profile))

    def add_result(result: dict[str, Any]) -> bool:
        source = str(result["source"])
        key = (source, int(result.get("start_line", 1)), str(result.get("heading", "")))
        if key in selected_keys or source_counts[source] >= max_chunks_per_source:
            return False
        selected.append(result)
        selected_keys.add(key)
        source_counts[source] += 1
        return True

    if normalize_search_mode(mode) == "fdr":
        selected_roles: set[str] = set()
        seed_count = min(3, limit)
        role_insert_limit = min(limit, seed_count + 2)
        for result in ordered_results[:seed_count]:
            if add_result(result):
                selected_roles.add(str(result.get("fdr_role", "other")))
        for result in ordered_results[seed_count:]:
            if len(selected) >= role_insert_limit:
                break
            role = str(result.get("fdr_role", "other"))
            if role in selected_roles:
                continue
            if add_result(result):
                selected_roles.add(role)

    for result in ordered_results:
        if len(selected) >= limit:
            break
        add_result(result)
    return selected


def build_read_plan(
    results: list[dict[str, Any]],
    mode: str = "default",
    max_items: int = 6,
    config: dict[str, Any] | None = None,
    profile: dict[str, Any] | None = None,
) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    blocked: list[dict[str, Any]] = []
    seen_sources: set[str] = set()
    active_config = config or DEFAULT_CONFIG
    active_profile = profile or score_query_profile("", mode, None)
    read_plan_limit = adaptive_read_plan_limit(active_profile, max_items)
    ordered_results = sorted(results, key=lambda item: profile_result_sort_key(item, active_config, active_profile))
    for result in ordered_results:
        status = str(result.get("document_status", "normal"))
        entry = {
            "source": result.get("source"),
            "read_hint": result.get("read_hint"),
            "role": result.get("fdr_role", "other"),
            "section": result.get("section", ""),
            "status": status,
            "score": result.get("score"),
            "token_cost_hint": "low" if float(result.get("score", 0.0)) >= 0.55 else "medium",
        }
        if status in ("superseded", "historical"):
            blocked.append({**entry, "reason": "low-trust document status"})
            continue
        source = str(result.get("source", ""))
        if source in seen_sources:
            continue
        items.append(entry)
        seen_sources.add(source)
        if len(items) >= read_plan_limit:
            break
    return {
        "mode": normalize_search_mode(mode),
        "budget_hint": "Read only the listed sections first; avoid full-file reads unless these sections are insufficient.",
        "token_budget_hint": "Start with 1-2 low-cost sections, then expand only if evidence is still missing.",
        "items": items,
        "deprioritized": blocked[:3],
    }


def search_index_with_plan(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    query: str,
    top_k: int = 5,
    filter_source: str | None = None,
    filter_type: str | None = None,
    mode: str = "default",
    auto_reindex: bool = False,
) -> dict[str, Any]:
    freshness = ensure_fresh_index(root_arg, config_path, auto_reindex)
    results = search_index(root_arg, config_path, query, top_k, filter_source, filter_type, mode)
    profile = score_query_profile(query, mode, filter_source)
    diagnostics: dict[str, Any] = {
        "no_results": results == [],
        "explicit_paths": extract_query_paths(query),
        "index_stale_before_search": bool(freshness.get("stale_before")),
        "index_stale_reason": freshness.get("reason_before"),
        "index_reindexed": bool(freshness.get("reindexed")),
        "index_stale_after_search": bool(freshness.get("status", {}).get("stale")),
        "query_profile": {
            "broad": profile["broad"],
            "self_rag": profile["self_rag"],
            "knowledge_intent": profile["knowledge_intent"],
            "broad_implementation": profile["broad_implementation"],
        },
    }
    if results == []:
        diagnostics["next_steps"] = [
            "run rag_coverage for explicit paths mentioned in the query",
            "try a task-specific mode such as architecture, implementation, frontend, migration, or fdr",
            "reindex if rag_status reports stale source files",
        ]
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    return {
        "results": results,
        "read_plan": build_read_plan(results, mode, adaptive_read_plan_limit(profile), config, profile),
        "diagnostics": diagnostics,
    }


def search_index(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    query: str,
    top_k: int = 5,
    filter_source: str | None = None,
    filter_type: str | None = None,
    mode: str = "default",
    auto_reindex: bool = False,
) -> list[dict[str, Any]]:
    if auto_reindex:
        ensure_fresh_index(root_arg, config_path, True)
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    search_cache = load_search_cache(index_dir)
    if search_cache is not None:
        return search_precomputed_cache(search_cache, config, query, top_k, filter_source, filter_type, mode)

    chunks = load_chunks(index_dir)
    if not chunks:
        return []

    search_cfg = config.get("search", {})
    dim = int(search_cfg.get("hash_dim", 512))
    min_score = float(search_cfg.get("min_score", 0.02))
    preview_chars = int(search_cfg.get("preview_chars", 500))
    vector_weight = float(search_cfg.get("vector_weight", 0.45))
    bm25_weight = float(search_cfg.get("bm25_weight", 0.35))
    source_weight = float(search_cfg.get("source_weight", 0.14))
    heading_weight = float(search_cfg.get("heading_weight", 0.06))
    base_max_chunks_per_source = max(1, int(search_cfg.get("max_chunks_per_source", 2)))

    search_mode = normalize_search_mode(mode)
    profile = score_query_profile(query, search_mode, filter_source)
    max_chunks_per_source = adaptive_max_chunks_per_source(base_max_chunks_per_source, profile)
    expanded_query = expand_for_search_mode(query, config, search_mode)
    query_counts = trim_query_counts(token_counts(expanded_query), config)
    query_terms = set(query_counts)
    query_vector = hashed_vector(query_counts, dim)
    doc_counts = [token_counts(weighted_document_text(chunk)) for chunk in chunks]
    raw_bm25 = bm25_scores(query_counts, doc_counts)
    max_bm25 = max(raw_bm25) if raw_bm25 else 0.0

    results: list[dict[str, Any]] = []
    for index, chunk in enumerate(chunks):
        source = str(chunk.get("source", ""))
        chunk_type = str(chunk.get("artifact_type", ""))
        doc_status = str(chunk.get("document_status", "normal"))
        if filter_source and filter_source not in source:
            continue
        if filter_type and not chunk_type.startswith(filter_type):
            continue
        vector_score = max(cosine_sparse(query_vector, hashed_vector(doc_counts[index], dim)), 0.0)
        bm25 = raw_bm25[index] / max_bm25 if max_bm25 > 0 else 0.0
        source_match = overlap_score(query_terms, source)
        heading_match = overlap_score(query_terms, str(chunk.get("heading", "")))
        score = (
            vector_weight * vector_score
            + bm25_weight * bm25
            + source_weight * source_match
            + heading_weight * heading_match
        )
        penalty = source_penalty(source, config)
        doc_status_boost = status_boost(doc_status, config)
        role = fdr_role(source, chunk_type)
        intent_multiplier = intent_source_multiplier(source, chunk_type, role, profile)
        preview = re.sub(r"\s+", " ", str(chunk.get("text", ""))).strip()[:preview_chars]
        review_multiplier = review_term_multiplier(profile, source, str(chunk.get("heading", "")), preview)
        score *= artifact_boost(source, chunk_type, config)
        score *= fdr_role_boost(source, chunk_type, config, search_mode)
        score *= mode_source_boost(source, config, search_mode)
        score *= penalty
        score *= doc_status_boost
        score *= intent_multiplier
        score *= review_multiplier
        if score < min_score:
            continue
        start_line = int(chunk.get("start_line", 1))
        results.append(
            {
                "score": round(score, 6),
                "vector": round(vector_score, 6),
                "bm25": round(bm25, 6),
                "source_match": round(source_match, 6),
                "heading_match": round(heading_match, 6),
                "path_match": 0.0,
                "source_penalty": round(penalty, 6),
                "status_boost": round(doc_status_boost, 6),
                "intent_boost": round(intent_multiplier, 6),
                "review_boost": round(review_multiplier, 6),
                "fdr_role": role,
                "source": source,
                "heading": chunk.get("heading", ""),
                "section": chunk.get("heading", ""),
                "artifact_type": chunk_type,
                "document_status": doc_status,
                "start_line": start_line,
                "read_hint": read_hint(source, start_line, str(chunk.get("heading", ""))),
                "preview": preview,
            }
        )

    results.sort(key=lambda item: search_sort_key(item, config))
    return select_search_results(results, top_k, max_chunks_per_source, search_mode, config, profile)


def lookup_symbol(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    name: str,
    kind: str | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    symbols = load_json_list(get_index_dir(root, config) / "symbols.json")
    needle = name.lower()
    results = []
    for symbol in symbols:
        symbol_name = str(symbol.get("name", ""))
        short = symbol_name.rsplit("\\", 1)[-1].rsplit(".", 1)[-1]
        if symbol_name.lower() != needle and short.lower() != needle:
            continue
        if kind and symbol.get("kind") != kind:
            continue
        results.append(symbol)
    results.sort(key=lambda item: (item.get("source", ""), item.get("line", 0), item.get("kind", "")))
    return results[: max(1, min(int(limit), 50))]


def lookup_deps(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    target: str,
    direction: str = "reverse",
    limit: int = 20,
) -> list[dict[str, Any]]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    deps = load_json_list(get_index_dir(root, config) / "deps.json")
    needle = target.lower()
    results = []
    for dep in deps:
        source = str(dep.get("source", ""))
        dep_target = str(dep.get("target", ""))
        if direction == "forward":
            matched = needle in source.lower()
        else:
            short = dep_target.rsplit("\\", 1)[-1].rsplit("/", 1)[-1].rsplit(".", 1)[-1]
            matched = needle in dep_target.lower() or short.lower() == needle
        if matched:
            results.append(dep)
    results.sort(key=lambda item: (item.get("source", ""), item.get("target", ""), item.get("line", 0)))
    return results[: max(1, min(int(limit), 50))]
