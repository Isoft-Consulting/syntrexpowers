# 11. Phased Implementation

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).

This sub-spec is an index for the v0 build phases. Phase contracts live under `11-phases/`.

| Phase | Sub-spec | Scope |
|---:|---|---|
| 0 | [Payload Discovery](11-phases/00-payload-discovery.md) | Capture provider payloads and fixture proofs before enforcement |
| 1 | [Universal Install Skeleton](11-phases/01-universal-install-skeleton.md) | Single package install, config merge, manifest, rollback |
| 2 | [Health And Prompt Injection](11-phases/02-health-and-prompt-injection.md) | Hook health and user prompt reminders |
| 3 | [Destructive Shell Gate](11-phases/03-destructive-shell-gate.md) | Shell, protected path, opt-out, and approval anti-forgery gates |
| 4 | [Edits Tracking And Stub Scan](11-phases/04-edits-tracking-and-stub-scan.md) | Current-turn scope tracking and stub enforcement |
| 5 | [FDR Artifact Validation](11-phases/05-fdr-artifact-validation.md) | Trusted artifact import, validation, and missing/stale gating |
| 6 | [Judge Router](11-phases/06-judge-router.md) | Claude Haiku and Codex Spark judge invocation |
| 7 | [FDR Challenge](11-phases/07-fdr-challenge.md) | Semantic challenge cycles after artifact validation |
| 8 | [Bounded Worker Delegation](11-phases/08-bounded-worker-delegation.md) | Token-saving file-level worker prompts and provenance |

## Phase Rules

- Later phases depend on all earlier phase acceptance gates.
- A phase cannot claim enforcing activation until its provider fixtures, exact schemas, and failure behavior are covered in [Test Strategy](12-test-strategy.md).
- A phase that touches normalized events, trusted JSON, JSONL, markers, manifests, fixtures, protected text config, decisions, provider output, or matrix behavior cannot claim enforcing readiness until the affected schema ids and matrix ids in [Implementation Readiness](17-implementation-readiness.md) have every applicable required artifact: protected metadata files, implemented parser or validator entrypoints, valid and malformed fixtures, hash validation where applicable, positive and negative matrix coverage where applicable, and fail-closed tests.
- Provider parity gaps must stay explicit: unsupported enforcement remains discovery/log-only or fails activation when required for safety.
