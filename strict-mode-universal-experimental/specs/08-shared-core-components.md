# 8. Shared Core Components

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).

This sub-spec is an index for provider-neutral enforcement components. Component contracts live under `08-shared-core/`.

| Component | Sub-spec | Scope |
|---:|---|---|
| 8.1 | [Stub Scan](08-shared-core/01-stub-scan.md) | Stop-time and pre-write stub detection |
| 8.2 | [Pre-Write Scan](08-shared-core/02-pre-write-scan.md) | Normalized pre-tool content scanning |
| 8.3 | [Record Edit](08-shared-core/03-record-edit.md) | Tool intent, permission, tool, edit, sequence, and dirty-snapshot records |
| 8.4 | [Stop Guard](08-shared-core/04-stop-guard.md) | Stop-time quality gate aggregation and bypass handling |
| 8.5 | [Destructive Gate](08-shared-core/05-destructive-gate.md) | Dangerous command and protected path blocking |
| 8.6 | [FDR Challenge](08-shared-core/06-fdr-challenge.md) | Semantic judge challenge cycles |
| 8.7 | [Static Prepass](08-shared-core/07-static-prepass.md) | Post-tool warnings before Stop |
| 8.8 | [Prompt Injection And Health Check](08-shared-core/08-prompt-injection-and-health-check.md) | User prompt reminders and hook health status |
| 8.9 | [Trivial Diff Detector](08-shared-core/09-trivial-diff-detector.md) | Skip rules for low-risk edit scopes |
| 8.10 | [Stop Orchestration](08-shared-core/10-stop-orchestration.md) | Final Stop decision order |
| 8.11 | [Bounded Worker Delegation](08-shared-core/11-bounded-worker-delegation.md) | Token-saving file-level worker prompts and provenance |

## Shared Invariants

- Provider-specific extraction stays in normalizers or provider adapters; enforcement decisions stay in these shared-core contracts.
- A later `allow` cannot override an earlier `block`; approved quality bypass consumption removes only the exact matching quality block inside the final allow-side transaction.
- State, approval, artifact, and sequence evidence must be read through the protected state contracts in [State Layout](07-state-layout.md).
- Worker-model output is advisory until accepted through normal tool/edit/FDR state. A worker cannot create approvals, bypasses, clean FDR verdicts, or provider allow decisions.
- Any schema change in a component sub-spec must update [Test Strategy](12-test-strategy.md) and [Acceptance Criteria For v0](15-acceptance-criteria-v0.md) when behavior or release gates change.
