# Phase 8 — Bounded Worker Delegation

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: reduce token cost for narrow file-level development and review tasks without granting worker models enforcement authority.

Deliverables:

- `strict-worker`
- `worker.context-pack.v1` builder and parser
- `worker.invocation.v1` trusted-state append path
- `worker.result.v1` parser and result binder
- provider-bound cheap worker routing
- protected runtime config keys for worker model, timeout, context byte cap, result byte cap, and per-provider disable flags
- fixture-proven prompt delivery, sandbox/no-tool behavior, timeout, output shape, and provider state isolation
- stale-result detection by content-scope fingerprint and context-pack hash

Acceptance:

- context packs contain only declared paths, bounded excerpts, hashes, task kind, constraints, and output expectations
- context packs reject protected files, strict-mode state/config, provider config, raw transcripts, secrets, and hidden history
- Claude worker route uses only fixture-proven cheap Haiku-class worker models
- Codex worker route uses only fixture-proven cheap Spark-class worker models
- generated runtime config disables real worker routes by default until installed-version `worker-invocation` proof exists
- discovery-skeleton runtime config rejects provider worker enable flags until there is a protected proof-bound enable path
- worker model, timeout, context cap, result cap, and disable settings are accepted only from protected runtime config, never provider environment or project files
- cross-provider worker routing is rejected
- worker output cannot create allow, bypass, approval, clean FDR, or Stop decisions
- patch/rewrite results touching paths outside the declared context pack are rejected
- stale worker results are rejected when source fingerprints, diff hunks, relevant constraints, task kind, or output expectation change
- worker failure maps to advisory `unknown` and does not disable normal FDR, Stop, destructive, protected-root, or artifact gates
- worker records are hash-bound and cannot be used as trusted evidence without matching invocation, context-pack, model route, and result hashes

---
