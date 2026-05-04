#!/usr/bin/env bash
# rollback.sh — восстанавливает хуки из последнего бекапа в ~/.claude/backups/.
# Идемпотентен: повторный запуск восстанавливает то же состояние.
#
# Usage:
#   bash rollback.sh                  # restore latest backup of each hook
#   bash rollback.sh --tag <tag>      # restore specific bundle DATE_TAG
#   bash rollback.sh --list           # list available backups, exit
#
set -uo pipefail
# NOT set -e: ls на missing backup pattern returns 1 (no match), которое sets -e ловит
# и прерывает скрипт молча. Используем `|| true` локально + явный check на каждом ls.

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
BACKUP_DIR="$CLAUDE_DIR/backups"

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "FATAL: no backup directory at $BACKUP_DIR — nothing to roll back" >&2
  exit 1
fi

# --list mode
if [[ "${1:-}" = "--list" ]]; then
  echo "Available hook backups in $BACKUP_DIR:"
  ls -1 "$BACKUP_DIR"/*.bak-* 2>/dev/null | sort
  exit 0
fi

# --tag <tag> mode (restore specific deploy)
TAG=""
if [[ "${1:-}" = "--tag" && -n "${2:-}" ]]; then
  TAG="$2"
fi

# Atomic restore — same pattern as install.sh atomic_deploy.
restore_hook() {
  local backup="$1" target="$2"
  local tmp="${target}.restore.$$"
  cp "$backup" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$target"
}

HOOKS=(health-check.sh prompt-inject.sh pre-write-scan.sh record-edit.sh stop-guard.sh stub-scan.sh fdr-challenge.sh judge.sh prune-mem.py is-trivial-diff.sh fdr-validate.sh)

RESTORED=0
SKIPPED=0
for hook in "${HOOKS[@]}"; do
  if [[ -n "$TAG" ]]; then
    # Match exact tag (with optional PID/counter suffix)
    backup=$(ls -1 "$BACKUP_DIR/${hook}.bak-${TAG}"* 2>/dev/null | sort | tail -1 || true)
  else
    # Latest backup для этого хука
    backup=$(ls -1 "$BACKUP_DIR/${hook}.bak-"* 2>/dev/null | sort | tail -1 || true)
  fi
  if [[ -n "$backup" && -f "$backup" ]]; then
    if [[ -f "$HOOKS_DIR/$hook" ]] && cmp -s "$backup" "$HOOKS_DIR/$hook"; then
      echo "  = $hook (already matches backup, skip)"
      SKIPPED=$((SKIPPED + 1))
    else
      restore_hook "$backup" "$HOOKS_DIR/$hook"
      echo "  ↶ $hook ← ${backup##*/}"
      RESTORED=$((RESTORED + 1))
    fi
  fi
done

echo ""
echo "Restored: $RESTORED, skipped (idempotent): $SKIPPED"
echo ""
if [[ "$RESTORED" -gt 0 ]]; then
  echo "Note: hooks reload on next fire (no Claude Code restart needed),"
  echo "but settings.json hooks-block changes require new session."
fi
