# 12. Test Strategy

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).

This sub-spec is an index for v0 test coverage. Test contracts live under `12-tests/`.

| Test Layer | Sub-spec | Scope |
|---:|---|---|
| 12.1 | [Pure Core Tests](12-tests/01-pure-core-tests.md) | Provider-free shared logic and exact schema validation |
| 12.2 | [Provider Fixture Tests](12-tests/02-provider-fixture-tests.md) | Claude/Codex payload, matcher, event-order, prompt, judge, and decision fixtures |
| 12.3 | [Installer Tests](12-tests/03-installer-tests.md) | Install, rollback, manifest, baseline, and config writer behavior |
| 12.4 | [Smoke Tests](12-tests/04-smoke-tests.md) | End-to-end safety checks under Claude and Codex |

## Coverage Rules

- Every behavioral contract in [Shared Core Components](08-shared-core-components.md) needs at least one pure core or smoke assertion unless it is explicitly fixture-only.
- Every provider-specific claim in [Hook Event Matrix](03-hook-event-matrix.md), [Provider Verification And Detection](05-provider-verification-and-detection.md), [Decision Contract](06-decision-contract.md), and [Judge Router](09-judge-router.md) needs fixture coverage.
- Every install, rollback, manifest, or config writer claim in [Install And Uninstall](10-install-and-uninstall.md) needs installer coverage.
- Every README/provider support matrix claim needs an installer or fixture test proving the documented status and proof text are in the closed provider-feature enums and match the enabled runtime behavior.
- Every schema id and matrix id in [Implementation Readiness](17-implementation-readiness.md) needs an exact markdown-to-metadata registry match plus every applicable required artifact before the owning feature can enforce: parser or validator coverage, valid inputs, every owner-defined variant/directive/action shape, format-specific malformed inputs, hash-mismatch when applicable, tuple-mismatch when applicable, every allowed matrix row where applicable, and invalid-combination cases where a matrix is involved.
