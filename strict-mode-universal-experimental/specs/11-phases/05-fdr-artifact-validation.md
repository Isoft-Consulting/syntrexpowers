# Phase 5 — FDR Artifact Validation

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: shared artifact gate independent of provider.

Deliverables:

- universal `fdr-validate.sh`
- `strict-fdr import` through the verified active runtime
- provider-scoped artifact names
- strict-mode-owned artifact import from untrusted project markdown
- discovery-only `STRICT_NO_ARTIFACT_GATE=1` downgrade before Phase 5 enforcement

Acceptance:

- valid artifact allows stop
- invalid artifact blocks stop
- normalized state-root artifact must contain the exact `json strict-fdr-v1` fenced JSON schema
- missing or stale artifact blocks Stop in Phase 5/enforcing v0 unless an approved project quality-gate opt-out covers the gate
- `STRICT_NO_ARTIFACT_GATE=1` is rejected as a protected config error once Phase 5/enforcing v0 is active
- FDR challenge state represents missing artifacts with `artifact_state=missing` and `artifact_hash` as 64 zeroes
- trusted import runs dirty-snapshot merge and freezes coverage cutoffs before validating artifact coverage
- trusted import ignores source-supplied tuple, freshness, coverage, path-list, and provenance fields and recomputes them from trusted state
- trusted import provenance command is excluded from review coverage only when exact argv/hash/source/artifact/provider/session/raw-session/cwd/project match
- trusted import post-tool record exclusion requires exactly one matching trusted post-cutoff tool record bound by `pre_tool_intent_seq/hash`, command hash/source, tuple, and zero edit records
- trusted import provenance has an exact schema; missing fields, extra fields, non-canonical paths, or hash mismatches reject the exclusion
- `review_generated_at` is advisory; freshness is proven by frozen sequence coverage, log digests, and `imported_at` recorded after dirty-snapshot merge
- Stop dirty-snapshot refresh uses import-freeze compare-only mode when a trusted state-root artifact exposes freeze metadata and never silently appends covered edit records after import
- artifact edited path list must match current-turn edit scope
- stale artifact whose exact sequence lists or log digests do not cover current-turn tool-intent/tool/edit entries blocks stop
- provider tools cannot directly create trusted state-root FDR artifacts
- `strict-fdr import -- <path>` is the only v0 path for creating trusted FDR artifacts from project markdown
- `strict-fdr import` command fingerprint is verified before it may write trusted artifact state
- trusted import command matching uses argv/shell-lexer parsing, not regex-only matching
- trusted import rejects out-of-project sources, protected-root sources, symlink components, devices, FIFOs, sockets, directories, oversize files, and protected-root hardlinks through `dev+inode` comparison
