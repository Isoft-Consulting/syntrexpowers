# Syntrexpowers

3 custom skills + 1 hook-based enforcement system + 1 experimental universal RAG toolkit that augment [Superpowers](https://github.com/obra/superpowers). Not a replacement — an addon. Superpowers stays installed and updates normally.

**Components:**
- **3 Skills** (LLM-driven, opt-in via triggers) — see `Skills` section below.
- **Strict Mode** (hook-driven, always-on enforcement) — see `Strict Mode` section.
- **Universal RAG Experimental** (provider-neutral MCP/CLI search) — see `rag-universal-experimental/`.

## Skills

### enhanced-code-review
Replaces `superpowers:requesting-code-review` trigger with structured protocol:
- **9 review layers** — requirements, architecture, logic, contracts, data, security, reliability, performance, tests
- **7 trace vectors** — caller→callee, data flow, error propagation, cross-module, state lifecycle, absence audit, numerical parity
- **Proof model** — every finding requires: source (file:line) + reachable path + harm. Missing any = not a finding
- **Phase 0 mechanical pre-sweep** — grep for numeric assertions, vacuous tests, TODO/FIXME before LLM (zero token cost)
- **Compact output** — findings + verdict only, no strengths/recommendations/narration
- **Graduated depth** — 1-3 files: layers only, 4-10: + key vectors, 10+: full matrix

### design-review
Works alongside `superpowers:brainstorming` for designing systems, modules, plugins, widgets, UI:
- **7-level decomposition framework** — Supersystem → Mission → Concept → Values → Skills → Behaviors → Environment
- **Consistency checks** — completeness, mission alignment, values→skills→behaviors chain, cross-level coherence
- **Spec review mode** — placeholder scan, internal contradictions, actionability, missing sections
- **Depth by granularity** — sandbox: full 7 levels, widget: 5 levels, component: 3 levels

### enhanced-planning
Works alongside `superpowers:writing-plans`:
- **Design validation** — verify 7-level framework before writing plan
- **Mechanical verification** — each task gets grep/bash verification commands (zero LLM cost)
- **Cross-task consistency** — dependency chains, numeric parity, no orphan tasks
- **Plan self-review checklist** — completeness, verification coverage, no placeholders

## Installation

### Claude Code

```bash
# Copy skills to Claude Code skills directory
mkdir -p ~/.claude/skills
cp -r skills/enhanced-code-review ~/.claude/skills/
cp -r skills/design-review ~/.claude/skills/
cp -r skills/enhanced-planning ~/.claude/skills/
```

Restart session. Skills appear alongside superpowers automatically.

### Codex CLI

```bash
# Copy skills to Codex skills directory
cp -r skills/enhanced-code-review ~/.codex/skills/
cp -r skills/design-review ~/.codex/skills/
cp -r skills/enhanced-planning ~/.codex/skills/
```

### Update

```bash
cd ~/syntrexpowers && git pull
# Then re-copy skills to ~/.claude/skills/ and/or ~/.codex/skills/
```

## Strict Mode

Hook-based enforcement system for Claude Code that **mechanically** forces the agent to finish code, run honest FDR (Full Deep Review), and spend fewer tokens. Unlike skills (model decides when to use), strict-mode hooks fire automatically on every relevant event — agent cannot bypass without explicit user authorization.

**Three deployed waves (all active):**

| Wave | What | Status |
|------|------|--------|
| **Wave 1** — Token economy | Slim EN `CLAUDE.md` with RU output policy, `prune-mem.py` for `claude-mem-context` blocks (−5..10k tokens/turn) | ✅ active |
| **Wave 2** — Foundation hooks | Stub-detection at write-time (PHP/Go/JS/TS/Python), edits-log, stop-guard re-scan, SessionStart health-check | ✅ active |
| **Wave 2.5** — Honesty challenge | FDR verdict-pattern detection (11 classes), Haiku-judge classifier, missing-verdict trigger, meta-bypass via magic-string, recursion guard | ✅ active |

**What gets blocked:**
- `// TODO`, `panic("not implemented")`, `throw new Error("TODO")`, `die("stub")`, RU markers (`дореал`, `доделат`) at write-time → `PreToolUse` exit 2.
- Stop-event with stubs in session-edited files.
- `0 проблем` / `Verdict: ready` / `N findings closed` in FDR-context → challenge with «продолжай develop→FDR→fix цикл».
- Code edits + FDR-context but no verdict in final message → block «дай verdict».
- Bare `0 проблем` without rationale → judge classifies as `evasive`, demands specifics.

**Bypass mechanisms:** self-magic-string for meta-discussion, hard one-shot bypass file, per-project disable, per-line `// allow-stub: <reason>`.

**149 tests** covering all paths.

Full feature list, install instructions, troubleshooting → [`strict-mode/README.md`](strict-mode/README.md). Design spec (16 sections, FDR'd) → [`strict-mode/docs/claude-code-strict-mode-v1.md`](strict-mode/docs/claude-code-strict-mode-v1.md).

```bash
# Install (idempotent):
cd strict-mode && bash install.sh
# Then restart Claude Code session (settings.json read at session start).

# IMPORTANT: Phase 2 ships an FDR artifact-gate that blocks every Stop
# with code edits if Phase 3 (/fdr skill) is not yet deployed. Until
# Phase 3 ships, set the transitional flag in your shell rc:
export STRICT_NO_ARTIFACT_GATE=1
# This disables artifact-gate checks (a) and (c). Wave 2.5 honesty
# challenge + Wave 3 validator (b) + sensitive verifier (d) remain active.
```

## Workflow

```
superpowers:brainstorming + design-review (7 levels)
    → superpowers:writing-plans + enhanced-planning (validation)
    → implementation (superpowers:subagent-driven-development)
    → enhanced-code-review (9 layers + proof model)

  + Strict Mode hooks running underneath:
    → blocks stubs at write-time
    → challenges verdicts in FDR-context
    → demands rationale or list of findings
```

Superpowers handles the flow. Our skills add structure and rigor at key points. Strict Mode adds mechanical enforcement that the model cannot ignore.

## Based On

- [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent — the workflow engine
- [7-level decomposition framework](https://github.com/Isoft-Consulting/core/blob/main/Docs/specs/design-decomposition-framework-v1.md) — design methodology
- A/B tested proof model and mechanical pre-sweep on real 26-file review scope

## License

MIT
