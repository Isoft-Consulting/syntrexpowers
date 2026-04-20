---
name: design-review
description: Use INSTEAD of or TOGETHER WITH superpowers:brainstorming when designing systems, modules, plugins, widgets, sandbox type-packs, UI pages, or reviewing specs/design docs. Enforces 7-level decomposition framework (Mission → Concept → Values → Skills → Behaviors → Environment + Supersystem). Triggers on "проектирование", "спека", "spec", "design", "виджет", "widget", "плагин", "plugin", "модуль", "module", "sandbox", "type-pack", "UI", "страница", "page".
---

# Design Review — 7-Level Decomposition Framework

Enforces structured design through 7 logical levels. Use for designing AND reviewing specs/plans/UI.

**When this skill triggers alongside superpowers:brainstorming — run brainstorming first, then apply this framework to validate the design before writing spec.**

## 7 Logical Levels

Every system, module, plugin, widget, or page must be defined through all 7 levels (top-down):

| # | Level | Key Question | Defines |
|---|-------|-------------|---------|
| 7 | **Supersystem** | What higher-order system are we in? | Platform constraints, ecosystem boundaries |
| 6 | **Mission** | Why does this exist? | One sentence starting with a verb |
| 5 | **Concept** | What IS this? What is it NOT? | Identity, boundaries, what's excluded |
| 4 | **Values** | What matters? What we never sacrifice? | Design principles, UX priorities (3-6 items) |
| 3 | **Skills** | What can it do? | Capabilities, functional features |
| 2 | **Behaviors** | What does it do? | Concrete scenarios, user flows |
| 1 | **Environment** | Where, with whom, when? | Users, integrations, dependencies, data |

## Consistency Checks

After defining all 7 levels, verify:

| Check | Question | Typical Defect |
|-------|----------|---------------|
| Completeness | All 7 levels defined? None empty? | Missing level |
| Mission alignment | Module mission is sub-mission of system mission? | Module solves wrong problem |
| Concept clarity | Defined what it is NOT? | Blurred responsibility boundary |
| Values → Skills | Every value supported by a skill? | Value without implementation |
| Skills → Behaviors | Every skill realized by a behavior? | Skill without scenarios |
| Behaviors → Environment | Environment sufficient for all behaviors? | Behavior without integration |
| Cross-level coherence | No orphan skills/behaviors? | Skill serving no value |

## When to Apply

### Designing (before spec)
After brainstorming settles on an approach — run 7-level matrix on the chosen design:
1. Fill all 7 levels for the system/module
2. Run consistency checks
3. If gaps found — fix before writing spec
4. For complex systems — decompose into sub-modules, apply 7 levels to each

### Reviewing specs
For existing spec/design doc:
1. Extract implicit 7 levels from the text
2. Identify which levels are missing or vague
3. Run consistency checks
4. Report gaps as findings

### UI / Widgets / Pages
Focus on levels 6-2 (Mission, Concept, Values, Skills, Behaviors):
- Mission: what is this page/widget FOR?
- Values: what UX principles drive it?
- Skills: what can user do here?
- Behaviors: concrete interaction flows
- Skip deep Environment analysis unless integrations are complex

## Depth by Granularity

| Target | Depth |
|--------|-------|
| Sandbox / type-pack | Full 7 levels, all checks |
| Plugin / module | Full 7 levels, all checks |
| Widget / page | Mission, Concept, Values, Skills, Behaviors (5 levels) |
| Component | Mission, Skills, Behaviors (3 levels) |

## Spec-Specific Checks (when reviewing docs)

- **Placeholder scan:** grep TODO/TBD/FIXME → each is a finding
- **Internal contradictions:** section A says X, section B says NOT X
- **Actionability:** concrete enough to start implementation?
- **API contracts:** request/response/errors all defined?
- **Missing sections:** migrations, rollback, permissions?

## Output

When designing: present the 7-level matrix for approval.

When reviewing: findings-only format:

| SEV | file:section | claim | reality | harm |

If 0 findings → "Design consistent, 0 gaps found."
