#!/usr/bin/env bash
# uninstall.sh — откат Claude Code Strict Mode.
# Удаляет наши хуки из settings.json. Скрипты в ~/.claude/hooks/ оставляет (можно вернуть переустановкой).
# CLAUDE.md НЕ откатывает автоматически — слишком ценно для случайного перезаписи.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups"
DATE_TAG=$(date +%Y-%m-%d-%H%M%S)

echo "===================================================="
echo "Claude Code Strict Mode uninstaller"
echo "===================================================="
echo ""

# Бекап текущего settings
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
  mkdir -p "$BACKUP_DIR"
  cp "$CLAUDE_DIR/settings.json" "$BACKUP_DIR/settings.json.pre-uninstall-${DATE_TAG}"
  echo "✓ Backup: $BACKUP_DIR/settings.json.pre-uninstall-${DATE_TAG}"
fi

# Удалить наши хуки из settings.json (по path-substring)
python3 <<EOF
import json
from pathlib import Path
p = Path("$CLAUDE_DIR/settings.json")
if not p.exists():
    print("⏭ settings.json не существует, нечего удалять")
    exit(0)
s = json.loads(p.read_text())
hooks = s.get("hooks", {})
removed = []
our_scripts = ["health-check.sh", "prompt-inject.sh", "pre-write-scan.sh",
               "record-edit.sh", "stop-guard.sh", "fdr-challenge.sh"]
for evt in list(hooks.keys()):
    new_groups = []
    for grp in hooks[evt]:
        new_hooks = []
        for h in grp.get("hooks", []):
            cmd = h.get("command", "")
            if any(s in cmd for s in our_scripts):
                removed.append(f"{evt}: {cmd}")
            else:
                new_hooks.append(h)
        if new_hooks:
            grp["hooks"] = new_hooks
            new_groups.append(grp)
    if new_groups:
        hooks[evt] = new_groups
    else:
        del hooks[evt]
if not hooks:
    s.pop("hooks", None)
else:
    s["hooks"] = hooks

# Skill(*) и Agent(*) ОСТАВЛЯЕМ — могут быть полезны вне strict-mode

tmp = p.with_suffix(".json.tmp")
tmp.write_text(json.dumps(s, indent=2, ensure_ascii=False))
tmp.replace(p)
print(f"✓ settings.json обновлён, удалено хуков: {len(removed)}")
for r in removed:
    print(f"    - {r}")
EOF

echo ""
echo "Что НЕ откачено (намеренно):"
echo "  - ~/.claude/CLAUDE.md (твой, не трогаем — забекапили только при install)"
echo "  - ~/.claude/hooks/*.sh (скрипты остаются, можно вернуть install.sh)"
echo "  - ~/.claude/state/* (per-session state, безвреден)"
echo "  - ~/.claude/sensitive-paths.txt, stub-allowlist.txt"
echo ""
echo "Полный wipe (удалить вообще всё):"
echo "  rm -rf ~/.claude/hooks/{health-check,prompt-inject,pre-write-scan,record-edit,stop-guard,stub-scan,fdr-challenge,judge}.sh ~/.claude/hooks/prune-mem.py ~/.claude/hooks/tests"
echo ""
echo "Восстановить старый settings.json:"
echo "  cp $BACKUP_DIR/settings.json.bak-* ~/.claude/settings.json   # выбери самый ранний"
echo ""
echo "Готово. Откроешь новую сессию — хуки больше не сработают."
