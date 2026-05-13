#!/usr/bin/env bash
# deploy-to-project.sh — копирует RAG runtime в указанный проект, генерирует/мерджит
# project-local конфиги, опционально строит начальный индекс. Идемпотентен:
# повторный запуск синхронизирует server tree, не затирает project-local rag.config.json
# и сохраняет существующие entries в .mcp.json.

set -eu

usage() {
    cat <<'USAGE'
Usage: deploy-to-project.sh <project-path> [--no-index] [--no-mcp]
                            [--config-template <path>]

Steps performed:
  1. rsync rag-universal-experimental/ → <project>/.mcp/rag-server/
  2. Create .mcp/rag-server/rag.config.json from template (only if missing)
  3. Merge "rag" entry into <project>/.mcp.json (add if missing, leave other
     servers untouched, replace existing "rag" entry only if its command changed)
  4. Build initial RAG index (skip with --no-index)

Flags:
  --no-index           skip step 4 (useful for very large projects or CI)
  --no-mcp             skip step 3 (project does not use MCP)
  --config-template P  override rag.config.json source (default:
                       rag.config.example.json from toolkit)

The script never overwrites an existing .mcp/rag-server/rag.config.json and
never silently drops other MCP servers from .mcp.json.
USAGE
}

if [ $# -lt 1 ]; then
    usage
    exit 2
fi

PROJECT=""
SKIP_INDEX=0
SKIP_MCP=0
CONFIG_TEMPLATE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --no-index)
            SKIP_INDEX=1
            shift
            ;;
        --no-mcp)
            SKIP_MCP=1
            shift
            ;;
        --config-template)
            if [ $# -lt 2 ]; then
                echo "deploy-to-project: --config-template requires an argument" >&2
                exit 2
            fi
            CONFIG_TEMPLATE="$2"
            shift 2
            ;;
        --*)
            echo "deploy-to-project: unknown flag: $1" >&2
            usage
            exit 2
            ;;
        *)
            if [ -n "$PROJECT" ]; then
                echo "deploy-to-project: only one project path allowed (got '$PROJECT' and '$1')" >&2
                exit 2
            fi
            PROJECT="$1"
            shift
            ;;
    esac
done

if [ -z "$PROJECT" ]; then
    usage
    exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ ! -d "$SOURCE" ] || [ ! -f "$SOURCE/tools/rag.py" ]; then
    echo "deploy-to-project: cannot locate RAG toolkit at $SOURCE" >&2
    exit 1
fi

if [ ! -d "$PROJECT" ]; then
    echo "deploy-to-project: project path does not exist: $PROJECT" >&2
    exit 1
fi

PROJECT=$(CDPATH= cd -- "$PROJECT" && pwd)
TARGET="$PROJECT/.mcp/rag-server"
MCP_JSON="$PROJECT/.mcp.json"
CONFIG_DEST="$TARGET/rag.config.json"

if [ -z "$CONFIG_TEMPLATE" ]; then
    CONFIG_TEMPLATE="$SOURCE/rag.config.example.json"
fi

# Шаг 1: rsync (с теми же исключениями что AGENT_INSTALL.md, плюс project-local
# файлы из core deploy doc для совместимости — secrets, .env, локальные конфиги)
mkdir -p "$TARGET"
rsync -a --delete \
    --exclude '.rag-index/' \
    --exclude 'rag.config.json' \
    --exclude 'evals/*-gold.json' \
    --exclude 'evals/local-*.json' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude '.secrets/' \
    --exclude '.mcp.json' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$SOURCE/" "$TARGET/"

echo "rsync done: $SOURCE → $TARGET"

# Шаг 2: rag.config.json только если отсутствует
if [ -f "$CONFIG_DEST" ]; then
    echo "rag.config.json already exists at $CONFIG_DEST — preserved"
else
    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        echo "deploy-to-project: config template not found: $CONFIG_TEMPLATE" >&2
        exit 1
    fi
    cp "$CONFIG_TEMPLATE" "$CONFIG_DEST"
    echo "created $CONFIG_DEST from $CONFIG_TEMPLATE"
fi

# Шаг 3: merge .mcp.json (используем python3 для безопасного JSON merge)
if [ "$SKIP_MCP" -eq 0 ]; then
    python3 - "$MCP_JSON" <<'PYTHON'
import json
import os
import sys

path = sys.argv[1]
entry = {
    "type": "stdio",
    "command": "python3",
    "args": [
        ".mcp/rag-server/tools/rag.py",
        "--root",
        ".",
        "--config",
        ".mcp/rag-server/rag.config.json",
        "serve-mcp",
        "--require-explicit-root",
        "--cache-storage",
        "memory"
    ]
}

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data, dict):
        sys.stderr.write(f"deploy-to-project: {path} is not a JSON object\n")
        sys.exit(1)
    servers = data.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        sys.stderr.write(f"deploy-to-project: {path}.mcpServers must be an object\n")
        sys.exit(1)
    existing = servers.get("rag")
    if existing == entry:
        print(f"{path} already has matching rag entry — unchanged")
    else:
        servers["rag"] = entry
        with open(path, "w", encoding="utf-8") as fp:
            json.dump(data, fp, indent=2, ensure_ascii=False)
            fp.write("\n")
        print(f"merged rag entry into {path}")
else:
    data = {"mcpServers": {"rag": entry}}
    with open(path, "w", encoding="utf-8") as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
        fp.write("\n")
    print(f"created {path} with rag entry")
PYTHON
fi

# Шаг 4: build index
if [ "$SKIP_INDEX" -eq 0 ]; then
    echo "building initial index (may take several minutes on large projects)..."
    python3 "$TARGET/tools/rag.py" index --root "$PROJECT" --config "$CONFIG_DEST" >/dev/null
    python3 "$TARGET/tools/rag.py" status --root "$PROJECT" --config "$CONFIG_DEST" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('manifest',{}); print(f'index built: num_files={m.get(\"num_files\",\"?\")} num_chunks={m.get(\"num_chunks\",\"?\")} num_symbols={m.get(\"num_symbols\",\"?\")}')"
fi

echo "deploy-to-project: done for $PROJECT"
