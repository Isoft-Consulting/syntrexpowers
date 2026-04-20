# Syntrexpowers

3 custom skills that augment [Superpowers](https://github.com/obra/superpowers). Not a replacement — an addon. Superpowers stays installed and updates normally.

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

## Workflow

```
superpowers:brainstorming + design-review (7 levels)
    → superpowers:writing-plans + enhanced-planning (validation)
    → implementation (superpowers:subagent-driven-development)
    → enhanced-code-review (9 layers + proof model)
```

Superpowers handles the flow. Our skills add structure and rigor at key points.

## Based On

- [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent — the workflow engine
- [7-level decomposition framework](https://github.com/Isoft-Consulting/core/blob/main/Docs/specs/design-decomposition-framework-v1.md) — design methodology
- A/B tested proof model and mechanical pre-sweep on real 26-file review scope

## License

MIT
