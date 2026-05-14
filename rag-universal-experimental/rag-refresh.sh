#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RAG_BIN="${SCRIPT_DIR}/tools/rag.py"
RAG_CONFIG="${SCRIPT_DIR}/rag.config.json"
RUN_QUALITY=0
FORCE_FULL=0
DAILY=0

if [[ ! -x "${RAG_BIN}" ]]; then
  echo "RAG CLI not found: ${RAG_BIN}" >&2
  exit 1
fi

if [[ ! -f "${RAG_CONFIG}" ]]; then
  echo "RAG config not found: ${RAG_CONFIG}" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: rag-refresh.sh [--quality] [--full] [--daily]

Run RAG status check and rebuild stale index.
  --full     force full reindex
  --daily    quick refresh mode: incremental when stale + quick smoke search
  --quality  run quality-check after refresh
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --full)
      FORCE_FULL=1
      shift
      ;;
    --quality)
      RUN_QUALITY=1
      shift
      ;;
    --daily)
      DAILY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${1}" >&2
      usage
      exit 2
      ;;
  esac
done

STATUS_JSON="$(mktemp)"
trap 'rm -f "${STATUS_JSON}"' EXIT

python3 "${RAG_BIN}" status --root "${ROOT_DIR}" --config "${RAG_CONFIG}" > "${STATUS_JSON}"

stale="$(python3 - "${STATUS_JSON}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    status = json.load(handle)

print("1" if status.get("stale") else "0")
PY
)"

python3 - "${STATUS_JSON}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    status = json.load(handle)

source_state = status.get("source_state", {}).get("current", {})
indexed_state = status.get("source_state", {}).get("indexed", {})
manifest = status.get("manifest", {})
print(
    "RAG status before refresh: "
    f"stale={str(bool(status.get('stale'))).lower()} "
    f"files={source_state.get('num_files')} "
    f"indexed={indexed_state.get('num_files')}"
)
print(f"manifest: build_mode={manifest.get('build_mode')} indexed_at={manifest.get('indexed_at')}")
PY

if [[ "${FORCE_FULL}" == "1" ]]; then
  python3 "${RAG_BIN}" index --root "${ROOT_DIR}" --config "${RAG_CONFIG}"
elif [[ "${stale}" == "1" ]]; then
  python3 "${RAG_BIN}" index --root "${ROOT_DIR}" --config "${RAG_CONFIG}" --incremental
else
  echo "RAG already fresh, skipping index."
fi

if [[ "${DAILY}" == "1" ]]; then
  python3 "${RAG_BIN}" search \
    --root "${ROOT_DIR}" \
    --config "${RAG_CONFIG}" \
    --mode knowledge \
    --top-k 3 \
    "project overview"
fi

if [[ "${RUN_QUALITY}" == "1" ]]; then
  if [[ "${DAILY}" == "1" ]]; then
    python3 "${RAG_BIN}" quality-check --root "${ROOT_DIR}" --config "${RAG_CONFIG}" --summary-only --no-auto-reindex
  else
    python3 "${RAG_BIN}" quality-check --root "${ROOT_DIR}" --config "${RAG_CONFIG}" --auto-reindex --summary-only
  fi
fi

python3 "${RAG_BIN}" status --root "${ROOT_DIR}" --config "${RAG_CONFIG}"
