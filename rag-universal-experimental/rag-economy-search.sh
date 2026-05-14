#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RAG_BIN="${SCRIPT_DIR}/tools/rag.py"
RAG_CONFIG="${SCRIPT_DIR}/rag.config.json"

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
Usage: rag-economy-search.sh [options] <query>

Options:
  --mode <mode>         Search mode: default|fdr|architecture|implementation|frontend|migration|knowledge (default: default)
  --top-k <N>           Number of results (default: 3 for economy mode)
  --filter-source <path> Optional source filter for initial lookup
  --filter-type <type>   Optional type filter for initial lookup
  --auto-reindex         Force auto-reindex before search
  --no-auto-reindex      Disable auto-reindex before search
  --with-plan            Enable detailed read plan
  --deep                 Shortcut: enable --with-plan and keep top-k=5 unless overridden
  --help                 Show this help

This helper defaults to token-economy mode: top-k=3 (unless overridden), no read-plan.
EOF
}

MODE="default"
TOP_K=3
FILTER_SOURCE=""
FILTER_TYPE=""
AUTO_REINDEX=""
WITH_PLAN=0
DEEP=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --mode)
      MODE="${2}"
      shift 2
      ;;
    --top-k)
      TOP_K="${2}"
      shift 2
      ;;
    --filter-source)
      FILTER_SOURCE="${2}"
      shift 2
      ;;
    --filter-type)
      FILTER_TYPE="${2}"
      shift 2
      ;;
    --auto-reindex)
      AUTO_REINDEX="--auto-reindex"
      shift
      ;;
    --no-auto-reindex)
      AUTO_REINDEX="--no-auto-reindex"
      shift
      ;;
    --with-plan)
      WITH_PLAN=1
      shift
      ;;
    --deep)
      DEEP=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    --*)
      echo "Unknown option: ${1}" >&2
      usage
      exit 2
      ;;
    *)
      POSITIONAL+=("${1}")
      shift
      ;;
  esac
done

if [[ ${DEEP} -eq 1 ]]; then
  WITH_PLAN=1
  if [[ "${TOP_K}" == "3" ]]; then
    TOP_K=5
  fi
fi

if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
  echo "Query is required." >&2
  usage
  exit 2
fi

QUERY="${POSITIONAL[*]}"

if [[ "${TOP_K}" == "" || "${TOP_K}" -lt 1 || "${TOP_K}" -gt 50 ]]; then
  echo "Invalid --top-k value: ${TOP_K}" >&2
  exit 2
fi

CMD=(python3 "${RAG_BIN}" search --root "${ROOT_DIR}" --config "${RAG_CONFIG}" --mode "${MODE}" --top-k "${TOP_K}")

if [[ "${AUTO_REINDEX}" != "" ]]; then
  CMD+=("${AUTO_REINDEX}")
fi
if [[ -n "${FILTER_SOURCE}" ]]; then
  CMD+=(--filter-source "${FILTER_SOURCE}")
fi
if [[ -n "${FILTER_TYPE}" ]]; then
  CMD+=(--filter-type "${FILTER_TYPE}")
fi
if [[ ${WITH_PLAN} -eq 1 ]]; then
  CMD+=(--with-plan)
fi
if [[ ${DEEP} -eq 1 ]]; then
  CMD+=(--no-economy)
fi
CMD+=("${QUERY}")

"${CMD[@]}"
