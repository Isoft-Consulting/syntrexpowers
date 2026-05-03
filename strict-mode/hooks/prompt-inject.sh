#!/usr/bin/env bash
# prompt-inject.sh — UserPromptSubmit hook.
# Инжектит strict-mode reminder в context на каждом турне.
# stdout попадает в context per Claude Code docs.
set -uo pipefail

# Recursion guard: если nested invocation (claude -p из judge.sh / fdr-verify.sh / триаж),
# не инжектить reminder — иначе вложенный claude видит правила и пытается их применить
# (наблюдалось: Haiku отвечал "meta-discussion, no FDR work" вместо классификации).
[[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0

# stdin есть, но мы его не парсим — просто инжектим текст.
cat <<'EOF'
[STRICT MODE]
1. No stubs (TODO/FIXME/not implemented). Code complete to working state.
2. After ANY edit (code/docs/config/migrations/specs/README): think through 9 FDR layers internally, fix found issues. NO 9-layer coverage table in chat — only real fixes + brief verdict.
3. Findings (when reported): file (+:symbol when actionable), expected vs actual, severity. Add :line only for CRITICAL/HIGH.
4. Do exactly what's asked. "Изучи" = study, not edit. When unsure, ask.
5. Reply in Russian. Code comments Russian. FDR/briefs English.
6. After code edits final message MUST contain explicit verdict: "0 проблем" + 1-3 sentence rationale (what was actually checked) if clean, OR list of open findings (file:symbol + severity). Bare "0 проблем" without rationale = sneaking out.
7. If Stop hook fired on meta-discussion (no actual FDR work in this turn) — reply with the phrase "meta-discussion, no FDR work" in a SHORT message (≤300 chars total) to self-bypass once.
EOF

exit 0
