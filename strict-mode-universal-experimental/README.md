# Strict Mode Universal Experimental

Status: draft documentation package with executable metadata scaffolding, provider proof fixtures, conservative payload normalization, discovery/log-only runtime installer skeleton, and enforcing install plan-only output. Enforcing hook activation and real provider fixture sets are not implemented in this directory yet.

Goal: one strict-mode package for Claude Code and Codex CLI without per-agent script forks. Provider-specific behavior must be selected from installer-generated provider identity and fixture-proven payload/decision contracts, not from ad hoc script forks.

Canonical contract: [SPEC.md](SPEC.md). Implementation cannot claim enforcing readiness until the metadata, schema, matrix, parser, fixture, and fail-closed gates in [Implementation Readiness](specs/17-implementation-readiness.md) are satisfied.

Current mechanical checks:

```bash
ruby tools/validate-metadata.rb
ruby tools/check-metadata-generated.rb
ruby tools/test-metadata-validator.rb
ruby tools/test-metadata-generator.rb
ruby tests/test-provider-detection.rb
ruby tests/test-normalized-events.rb
ruby tests/test-decisions.rb
ruby tests/test-protected-config.rb
ruby tests/test-destructive-gate.rb
ruby tests/test-protected-baseline.rb
ruby tests/test-preflight-record.rb
ruby tests/test-hook-preflight.rb
ruby tools/validate-fixtures.rb
ruby tests/test-fixtures.rb
ruby tests/test-fixture-readiness.rb
ruby tests/test-hook-entry-plan.rb
ruby tests/test-install-hook-plan.rb
ruby tests/test-installer.rb
```

Or run the combined local gate:

```bash
tests/run-tests.sh
```

`install.sh --enforce --plan-only` runs fixture readiness and emits a JSON hook plan with selected output contracts, but does not acquire install locks, copy releases, create transaction markers, or mutate provider configs. `--dry-run` is an alias for non-enforcing plan-only mode.

To inspect the current enforcing blockers as a structured report, run:

```bash
ruby tools/report-enforcement-readiness.rb --provider all --format json
```

This exits non-zero until the required provider fixture proofs exist.

This validates the generated `schemas/` and `matrices/` metadata against [Implementation Readiness](specs/17-implementation-readiness.md), including registry parity, duplicate-key-safe JSON parsing, exact metadata fields, hash fields, deterministic regeneration, README provider-matrix mapping, and negative fixtures for validator/generator/checker failure behavior. Provider detection tests exercise exact provider-proof records, payload indicator matching, mismatch/conflict/unknown rejection, proof hash validation, and duplicate-key payload rejection. Normalized event tests exercise the conservative payload normalizer, exact nested event shape, fail-closed sentinels, tool/write-intent domains, file_paths array extraction, patch rename path projection, permission network/filesystem detail extraction, duplicate-key payload rejection, logical-event mismatch rejection, network/path domain checks, and Codex `exec_command` shell mapping. Decision contract tests exercise `decision.internal.v1`, `decision.provider-output.v1`, captured stdout/stderr/exit-code matching, hash drift rejection, effectless block/deny/inject rejection, unsafe decision metadata rejection, and exact contract-id decision-output fixture binding. Protected config tests validate checked-in config templates plus runtime whitelist/bounds, strict protected/destructive/stub config failure behavior, symlink/path rejection, and network/filesystem allowlist config-error behavior. Destructive gate tests exercise read-only shell allow, shell destructive pattern blocking, protected-root redirects and `tee`, write-capable utility target extraction, final-symlink write-target blocking, shell wrapper handling, recursive command/process substitution classification, cwd-relative `.strict-mode` traversal, runtime script execution blocking including shell/process substitutions, exact `strict-fdr import -- <path>` exception behavior, direct write target blocking, protected hardlink aliases, shell parse errors, dynamic shell target rejection, and unknown write-target shell forms. Protected baseline tests exercise trusted install baseline loading, exact top-level manifest/baseline field and value rejection, manifest/baseline nested record parity, exact nested file-record field rejection, file-record canonical path/size/kind/provider checks, duplicate and unsorted nested file-record rejection, fixture manifest record schema/duplicate rejection, derived provider path, install-root-bound hook command, and generated hook env verification, protected root/inode export including the install manifest, managed hook/output-contract plan validation, configured protected paths and destructive patterns feeding the classifier, manifest hash tamper detection, protected content tamper detection, inode drift detection, and inode-index value, stale-key, and duplicate-entry rejection after hash recompute. Preflight record tests validate `hook.preflight.v1` exact fields, hash binding, duplicate-key-safe CLI parsing, not-attempted sentinels, untrusted diagnostic sentinels, trusted classifier decision coupling, and raw-command/redacted-hash shape. Hook preflight tests exercise discovery/log-only pre-tool normalization, protected baseline loading, classifier would-block logging including runtime command substitution and patch move into protected roots, safe shell allow logging, hash-bound preflight JSONL records, raw command redaction from JSONL, and untrusted-baseline diagnostics without provider enforcement. Fixture validation checks the checked-in Claude/Codex `fixture-manifest.json` files, canonicalizes fixture record hashes before manifest hashes during generation, imports opt-in captured JSON payloads into file-backed fixture records, writes raw payload, provider-proof, and validated `event.normalized.v1` fixture artifacts, binds all fixture files into `fixture_file_hashes`, rejects payload-schema records that do not regenerate from raw payload plus provider proof, rejects decision-output records whose metadata/captured output does not validate, and rejects unsafe fixture paths including symlink path components without treating empty manifests as proof. Fixture readiness tests verify concrete missing-proof diagnostics, installed-version versus `unknown-only` matching, range compatibility fail-closed behavior before comparator implementation, deterministic selected-output-contract records, block/deny-only decision-output selection for required blocking events, optional `permission-request` deny-output selection only after payload-schema and command-execution proof without making it a required v0 fixture, and install/baseline fixture-manifest record summaries. Hook entry plan tests bind future enforcing `pre-tool-use`, `stop`, and conditional `permission-request` entries to selected block/deny output contracts, keep discovery/non-blocking entries empty, reject outside-install-root or provider/event-drifted managed hook commands, and reject duplicate, unsorted, selector-drifted, or effectless contract plans. Install hook plan tests validate discovery hook generation, conditional `PermissionRequest` insertion from valid selected output proof, malformed selected-output rejection before conditional hook insertion, and provider timeout/matcher projection. The installer test runs in a temporary `HOME` and verifies discovery-only hook config generation, enforcing plan-only JSON output without provider mutation, idempotent reinstall, exact `state-global.lock/owner.json` records with owner parser rejection for extra fields, hash drift, invalid tuples, and stale-candidate checks, occupied global-lock refusal before install/uninstall mutation and rollback phase advance, clean active-path and provider/protected config preflight refusal without pending markers, ledger writes, or copied releases, dangling provider and Codex config symlink refusal before target creation, valid global ledger hash chains plus install/uninstall/rollback writer/target coverage, failed install promotion to `post-activation-failed` after provider config mutation, rollback refusal for stale `pre-activation` markers that require installer repair, reinstall rollback restoration of the previous active runtime symlink, active-link failure rollback restoration, unrelated active symlink refusal before rollback phase advance, marker/backup active-runtime path mismatch refusal before install rollback phase advance, uninstall marker/backup active-runtime path binding and mismatch refusal before uninstall recovery phase advance, rollback post-restore content drift refusal before complete marker publication, install and uninstall `rollback-in-progress` resume after post-restore drift, install/uninstall completed-pending cleanup before new transactions, completed-pending root/filename binding refusal, invalid completed-pending phase refusal before ledger repair, cross-writer complete-marker and pending-delete ledger refusal, duplicate complete-marker and pending-delete ledger refusal, complete-only rollback writer attribution refusal, completed rollback cleanup preserving rollback writer attribution, complete-marker ledger repair after write-before-ledger interruption, pending-delete ledger repair after delete-before-ledger interruption, missing pending-delete preimage refusal, unresolved pending-marker refusal before new install transactions, rollback complete-marker reuse after pending cleanup interruption, complete-marker binding drift refusal before pending cleanup, interrupted uninstall publication of `uninstall-failed` marker plus matching installer-marker ledger record, corrupted-ledger preflight refusal before uninstall mutation and rollback phase advance, and ledger validator rejection for invalid target classes, operation/fingerprint drift, non-lexical active-runtime targets, populated global tuples, and malformed fingerprints, exact hash-bound uninstall selectors with nonmatching-timeout preservation, uninstall protected-baseline and hook-plan validation before provider mutation, transaction marker schema-drift refusal, rollback backup manifest schema/summary/blob validation before phase advance, rollback restore-target symlink refusal, lexical `<install-root>/active/bin/strict-hook` commands, custom install-root state discovery, sorted unique manifest/baseline file-record arrays, copied provider-detection runtime helpers, manifest/baseline hashes, empty discovery selected-output-contract binding, hash-only provider-proof summary logging, provider-env raw-capture refusal, provider-env payload-cap refusal, protected-runtime raw payload capture only after provider match, provider-mismatch raw-capture refusal, and unsafe event-name path containment.

## Provider Support Matrix

| Capability | Claude Code | Codex CLI | Required proof before enforcement |
|---|---|---|---|
| Install/config merge | Planned | Planned | Structured config merge tests plus protected install baseline |
| `session-start` / `user-prompt-submit` | Fixture required | Fixture required | Event-order proof before model tool execution |
| `pre-tool-use` / `post-tool-use` | Fixture required | Fixture required | Payload schema, matcher, command execution, and decision-output fixtures |
| `stop` guard | Fixture required | Fixture required | Stop payload and block/continue output contract fixtures |
| `subagent-stop` | Claude only when fixture-proven | Disabled in v0 unless Codex exposes an equivalent hook | Event name, payload, and decision-output fixtures |
| `permission-request` | Not required by v0 bundle | Conditional | Required if fixtures show Codex can approve risky tools outside `pre-tool-use` |
| Destructive/protected-root gate | Planned after fixtures | Planned after fixtures | Exact provider block/deny contract and protected baseline verification |
| Edit tracking | Planned for Write/Edit/MultiEdit/shell | Planned for apply_patch/shell/write-like tools | Tool path evidence or fail-closed dirty-snapshot fallback |
| FDR artifact import | Planned | Planned | Verified `strict-fdr import -- <path>` provenance and artifact schema |
| Semantic judge route | Claude Haiku | Codex Spark | `judge-invocation` fixture proving prompt delivery, sandboxing, timeout, and state isolation |
| Bounded worker delegation | Claude Haiku | Codex Spark | `worker-invocation` fixture proving prompt delivery, no-tool sandboxing, timeout, output JSON shape, and state isolation |
| FDR challenge | Planned after current-turn extraction proof | Disabled until current-turn extraction fixture proof exists | Provider normalizer must prove bounded current-turn assistant-text extraction without persisting transcripts |

Provider support capability, status, and proof cells are controlled contract text for `matrix.provider-feature-gate.v1`, not free-form status prose. The closed status/proof enums and exact-cell mappings live in [Implementation Readiness](specs/17-implementation-readiness.md). Changing a capability, status, or proof cell requires updating the provider-feature matrix, installer/readiness checks, and fixture expectations in the same edit.

Codex FDR challenge parity is not claimed in this draft. If current-turn assistant-text extraction remains unproven for an installed Codex version/build, the installer must keep Codex FDR challenge disabled and the runtime must not silently fall back to transcript guessing.

## Safety Notes

- Unknown provider detection is fixture/manual mode only and cannot create trusted state.
- Provider tools cannot write strict-mode runtime, config, state, approval, bypass, or opt-out evidence.
- Judge routing is provider-bound: Claude uses Haiku, Codex uses Spark, and there is no cross-provider judge override in v0.
- Worker routing is provider-bound and advisory: Claude uses Haiku-class worker models, Codex uses Spark-class worker models, and worker output cannot authorize Stop, FDR clean, approvals, bypasses, or protected writes.
- Generated runtime config keeps real worker routes disabled until installed-version `worker-invocation` fixture proof exists; the discovery skeleton rejects provider worker enable flags before that proof-bound enable path exists.
- Project opt-outs and quality bypasses require exact hash-bound approval flows; current-turn provider-created files are not active evidence.
