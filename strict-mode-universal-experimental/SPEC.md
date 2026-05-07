# Strict Mode Universal Experimental - Specification v0

Status: draft
Target directory: `strict-mode-bundle/universal-experimental/`
Goal: one strict-mode package that runs under Claude Code and Codex CLI without per-agent script forks.

This file is the canonical index. The normative contract lives in the sub-specs under `specs/`.

## Reading Order

| Order | Sub-spec | Scope |
|---:|---|---|
| 0 | [Summary](specs/00-summary.md) | Shared runtime idea and provider-aware boundary |
| 1 | [7-Level Design](specs/01-7-level-design.md) | Mission, concept, values, skills, behaviors, environment |
| 2 | [Directory Layout](specs/02-directory-layout.md) | Planned files, roots, and ownership boundaries |
| 3 | [Hook Event Matrix](specs/03-hook-event-matrix.md) | Logical lifecycle events and provider support |
| 4 | [Normalized Event Contract](specs/04-normalized-event-contract.md) | Canonical event payloads consumed by shared core |
| 5 | [Provider Verification And Detection](specs/05-provider-verification-and-detection.md) | Runtime identity proof and provider mismatch handling |
| 6 | [Decision Contract](specs/06-decision-contract.md) | Internal allow/block/warn/inject decisions and provider emission |
| 7 | [State Layout](specs/07-state-layout.md) | Filesystem state, baselines, logs, locks, hashes |
| 8 | [Shared Core Components](specs/08-shared-core-components.md) | Enforcement modules: scans, edit tracking, Stop, FDR |
| 9 | [Judge Router](specs/09-judge-router.md) | Claude Haiku and Codex Spark routing |
| 10 | [Install And Uninstall](specs/10-install-and-uninstall.md) | Installer contracts, config writers, rollback, uninstall |
| 11 | [Phased Implementation](specs/11-phased-implementation.md) | Build phases and gating work |
| 12 | [Test Strategy](specs/12-test-strategy.md) | Core, fixture, installer, and smoke checks |
| 13 | [Risks And Constraints](specs/13-risks-and-constraints.md) | Known weak points and constraints |
| 14 | [Open Questions](specs/14-open-questions.md) | Decisions intentionally not frozen yet |
| 15 | [Acceptance Criteria For v0](specs/15-acceptance-criteria-v0.md) | Release gates |
| 16 | [Non-Goals For v0](specs/16-non-goals-v0.md) | Explicit exclusions |
| 17 | [Implementation Readiness](specs/17-implementation-readiness.md) | Schema registry, matrix validators, and parser/test gates |

## Maintenance Rules

- Change the smallest sub-spec that owns the contract.
- If a behavior changes, update the matching tests or acceptance criteria sub-spec in the same edit.
- If a schema changes, update its exact schema, canonical hash rules, fixture expectations, and failure behavior together.
- If a trusted schema, protected text config grammar, decision contract, normalized event, or matrix changes, update its stable id, implementation profile, metadata expectation, and fixture gates in [Implementation Readiness](specs/17-implementation-readiness.md) in the same edit.
- Keep provider-specific rules only in provider detection, normalization, decision emission, installer config writers, and judge routing.
- Keep shared enforcement semantics in shared-core sub-specs.

## FDR Entry Points

- Architecture review starts at [7-Level Design](specs/01-7-level-design.md), then checks provider boundaries in [Hook Event Matrix](specs/03-hook-event-matrix.md).
- Security review starts at [State Layout](specs/07-state-layout.md), [Decision Contract](specs/06-decision-contract.md), and [Shared Core Components](specs/08-shared-core-components.md).
- Installer review starts at [Install And Uninstall](specs/10-install-and-uninstall.md), then verifies release coverage in [Test Strategy](specs/12-test-strategy.md) and [Acceptance Criteria For v0](specs/15-acceptance-criteria-v0.md).
- Implementation review starts at [Implementation Readiness](specs/17-implementation-readiness.md), then checks that every touched trusted schema, protected text config grammar, decision contract, normalized event, and closed matrix has protected metadata, parser/validator coverage, valid and malformed fixtures, hash coverage when applicable, positive/negative matrix coverage where applicable, and fail-closed coverage before the owning phase can claim enforcing readiness.
