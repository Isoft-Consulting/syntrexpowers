# Syntrexpowers

Enhanced fork of [Superpowers](https://github.com/obra/superpowers) with improved code review: 9-layer review protocol, proof model, mechanical pre-sweep, and compact findings-only output.

## What's Different from Superpowers

| Feature | Superpowers | Syntrexpowers |
|---------|-------------|---------------|
| Code review layers | 5 generic categories | 9 structured layers |
| Trace vectors | — | 7 cross-file vectors (caller→callee, error propagation, numerical parity, etc.) |
| Proof model | — | Source + reachable path + harm (3 mandatory proof points) |
| Mechanical pre-sweep | — | Grep-based Phase 0 before LLM (zero token cost) |
| Output | Strengths + Issues + Recommendations | Findings-only + verdict |
| Severity levels | Critical / Important / Minor | Critical / High / Medium / Low |
| Review cycle | One-shot | Iterative: fix → re-review → 0 |

All original Superpowers skills are included (TDD, debugging, brainstorming, plans, subagent-driven development, etc.).

## Installation

### Claude Code

```bash
# 1. Add marketplace
claude plugins marketplace add Isoft-Consulting/syntrexpowers

# 2. Install plugin
claude plugins install syntrexpowers

# 3. (Optional) Disable original superpowers to avoid skill name conflicts
claude plugins disable superpowers
```

Restart Claude Code session after installation.

### OpenAI Codex CLI

```bash
# 1. Add marketplace
codex marketplace add Isoft-Consulting/syntrexpowers

# 2. Disable original superpowers (if installed)
mv ~/.codex/superpowers ~/.codex/_superpowers_disabled

# 3. Verify
codex # start new session, skills should show syntrexpowers:*
```

### Manual Installation (any platform)

Clone the repo and point your tool at it:

```bash
git clone git@github.com:Isoft-Consulting/syntrexpowers.git ~/syntrexpowers
```

**Claude Code:**
```bash
claude plugins marketplace add ~/syntrexpowers
claude plugins install syntrexpowers
```

**Codex CLI:**
```bash
codex marketplace add ~/syntrexpowers
```

## Usage

Skills trigger automatically — same as Superpowers. The enhanced code reviewer activates when you request code review or use `syntrexpowers:requesting-code-review`.

### Code Review Workflow

1. **Phase 0 (mechanical pre-sweep)** — grep for numeric assertions, vacuous tests, TODO/FIXME — zero LLM tokens
2. **9-layer review** — requirements, architecture, logic, contracts, data, security, reliability, performance, tests
3. **7 trace vectors** — caller→callee, data flow, error propagation, cross-module, state lifecycle, absence audit, numerical parity
4. **Proof model** — every finding must have: source (file:line) + reachable path + harm
5. **Iterative cycle** — fix → re-review → repeat until 0 findings

### All Skills

**Testing:** test-driven-development
**Debugging:** systematic-debugging, verification-before-completion
**Collaboration:** brainstorming, writing-plans, executing-plans, dispatching-parallel-agents, requesting-code-review, receiving-code-review, using-git-worktrees, finishing-a-development-branch, subagent-driven-development
**Meta:** writing-skills, using-superpowers

## Updating

```bash
# Claude Code
claude plugins update syntrexpowers

# Codex — re-add marketplace (pulls latest)
codex marketplace add Isoft-Consulting/syntrexpowers
```

## Based On

Fork of [obra/superpowers](https://github.com/obra/superpowers) v5.0.7. Original by [Jesse Vincent](https://blog.fsck.com) at [Prime Radiant](https://primeradiant.com).

## License

MIT License — see LICENSE file for details.
