from __future__ import annotations

import copy
import fnmatch
import hashlib
import json
import math
import os
import re
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

CONFIG_VERSION = "rag.config.v1"
MANIFEST_VERSION = "rag.index-manifest.v1"
CHUNK_VERSION = "rag.chunk.v1"
SYMBOL_VERSION = "rag.symbol.v1"
DEP_VERSION = "rag.dep-edge.v1"
CHUNKER_VERSION = "lexical-chunker.v1"
TOKENIZER_VERSION = "unicode-tokenizer.v1"
SEARCH_VERSION = "hash-vector-bm25.v2"

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
        "**/*token*",
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


def should_skip_dir(rel_dir: str, dirname: str, config: dict[str, Any]) -> bool:
    if dirname in set(config.get("exclude_dirs", [])):
        return True
    if not rel_dir:
        return False
    return matches_any(rel_dir, config.get("exclude_globs", [])) or matches_any(
        rel_dir, config.get("secret_path_patterns", [])
    )


def is_indexable_file(path: Path, root: Path, config: dict[str, Any]) -> bool:
    try:
        rel = path.relative_to(root).as_posix()
    except ValueError:
        return False
    if path.is_symlink() and not config.get("follow_symlinks", False):
        return False
    if not matches_any(rel, config.get("include_globs", [])):
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
    return {
        "schema_version": CHUNK_VERSION,
        "id": f"{source}:{ordinal}:{digest}",
        "source": source,
        "heading": heading,
        "artifact_type": artifact_type(source, heading),
        "start_line": start_line,
        "text": normalized,
        "text_sha256": sha256_text(normalized),
    }


def chunk_markdown(text: str, source: str, config: dict[str, Any]) -> list[dict[str, Any]]:
    sections: list[tuple[str, int, list[str]]] = []
    heading = Path(source).name
    start_line = 1
    buffer: list[str] = []
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


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def write_text_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    tmp.write_text(value, encoding="utf-8")
    os.replace(tmp, path)


def build_index(root_arg: str | os.PathLike[str] | None = None, config_path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)

    chunks: list[dict[str, Any]] = []
    symbols: list[dict[str, Any]] = []
    deps: list[dict[str, Any]] = []
    files: list[dict[str, Any]] = []

    for path in iter_indexable_files(root, config):
        file_chunks, text, raw = chunk_file(path, root, config)
        source = path.relative_to(root).as_posix()
        chunks.extend(file_chunks)
        symbols.extend(extract_symbols(text, source))
        deps.extend(extract_deps(text, source))
        files.append(
            {
                "source": source,
                "bytes": len(raw),
                "sha256": sha256_bytes(raw),
                "chunks": len(file_chunks),
            }
        )

    artifact_names = {
        "chunks": "chunks.jsonl",
        "symbols": "symbols.json",
        "deps": "deps.json",
        "files": "files.json",
    }
    manifest = {
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
        "artifacts": artifact_names,
    }

    chunk_lines = "".join(json.dumps(chunk, ensure_ascii=False, sort_keys=True) + "\n" for chunk in chunks)
    write_text_atomic(index_dir / artifact_names["chunks"], chunk_lines)
    write_json_atomic(index_dir / artifact_names["symbols"], symbols)
    write_json_atomic(index_dir / artifact_names["deps"], deps)
    write_json_atomic(index_dir / artifact_names["files"], files)
    write_json_atomic(index_dir / "manifest.json", manifest)
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


def index_status(root_arg: str | os.PathLike[str] | None = None, config_path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
    manifest = load_manifest(index_dir)
    expected_hash = config_hash(config)
    if manifest is None:
        return {
            "exists": False,
            "index_dir": str(index_dir),
            "config_hash": expected_hash,
            "stale": True,
            "reason": "missing manifest",
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
    return {
        "exists": True,
        "index_dir": str(index_dir),
        "stale": bool(stale_reasons),
        "reason": ", ".join(stale_reasons) if stale_reasons else None,
        "manifest": manifest,
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


def search_index(
    root_arg: str | os.PathLike[str] | None,
    config_path: str | os.PathLike[str] | None,
    query: str,
    top_k: int = 5,
    filter_source: str | None = None,
    filter_type: str | None = None,
) -> list[dict[str, Any]]:
    root = resolve_root(root_arg)
    config = load_config(root, config_path)
    index_dir = get_index_dir(root, config)
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
    max_chunks_per_source = max(1, int(search_cfg.get("max_chunks_per_source", 2)))

    expanded_query = expand_query(query, config)
    query_counts = token_counts(expanded_query)
    query_terms = set(query_counts)
    query_vector = hashed_vector(query_counts, dim)
    doc_counts = [token_counts(weighted_document_text(chunk)) for chunk in chunks]
    raw_bm25 = bm25_scores(query_counts, doc_counts)
    max_bm25 = max(raw_bm25) if raw_bm25 else 0.0

    results: list[dict[str, Any]] = []
    for index, chunk in enumerate(chunks):
        source = str(chunk.get("source", ""))
        chunk_type = str(chunk.get("artifact_type", ""))
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
        score *= artifact_boost(source, chunk_type, config)
        if score < min_score:
            continue
        preview = re.sub(r"\s+", " ", str(chunk.get("text", ""))).strip()[:preview_chars]
        results.append(
            {
                "score": round(score, 6),
                "vector": round(vector_score, 6),
                "bm25": round(bm25, 6),
                "source_match": round(source_match, 6),
                "heading_match": round(heading_match, 6),
                "source": source,
                "heading": chunk.get("heading", ""),
                "artifact_type": chunk_type,
                "start_line": chunk.get("start_line", 1),
                "preview": preview,
            }
        )

    results.sort(key=lambda item: (-item["score"], item["source"], item["start_line"]))
    limit = max(1, min(int(top_k), 50))
    diverse: list[dict[str, Any]] = []
    source_counts: Counter[str] = Counter()
    for result in results:
        source = str(result["source"])
        if source_counts[source] >= max_chunks_per_source:
            continue
        diverse.append(result)
        source_counts[source] += 1
        if len(diverse) >= limit:
            break
    return diverse


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
