# Phase 1 — Universal Install Skeleton

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: install one package and configure both providers.

Deliverables:

- `install.sh --provider claude|codex|all|auto`
- `uninstall.sh`
- `README.md` provider support matrix with experimental-status warnings
- recoverable staged deploy with atomic per-file renames
- config merge without duplicate hook entries
- install manifest for exact uninstall matching
- fixture readiness checker for concrete enforcing-activation missing-proof diagnostics
- protected text config parser and validator for `runtime.env`, protected paths, destructive patterns, stub allowlist, filesystem read allowlist, and network allowlist
- protected schema and matrix metadata plus hook-required provider detection helpers copied into the active runtime

Acceptance:

- re-running installer is idempotent
- existing non-strict hooks remain
- Codex `codex_hooks` enabled without removing existing `[features]`
- generated hook commands use the shell-quoted absolute lexical `<install-root>/active/bin/strict-hook` path, not `$HOME`, `~`, aliases, or provider environment expansion
- generated hook commands point at `<install-root>/active/bin/strict-hook`, not a realpath-resolved transaction release target
- generated hooks include protected `strict-hook` self-timeout values for every event, and provider-native outer timeout fields when supported with a fixture-proven guard gap beyond the self-timeout
- provider command execution fixtures prove leading env assignment and quoted install-root path semantics, or a protected provider-native env field is used; otherwise enforcing activation fails
- installer passes `--provider claude|codex` in every generated hook command
- Claude config uses a broad matcher or complete fixture-proven matcher set covering every required shell/write-like tool
- Claude `SubagentStop` hook entry is generated only after fixture proof that the event name and payload/decision contract are accepted
- Codex config uses a broad matcher, omitted matcher, or complete fixture-proven matcher set that covers every required shell/write-like tool for the installed Codex hook syntax
- Codex config writer refuses enforcing activation and does not publish trusted hook config when the installed Codex hook feature flag, hook config path, event names, matcher syntax, command execution, payload, or decision-output contract is not fixture-proven
- enforcing activation requests run a fixture readiness gate before provider config mutation; missing payload-schema, matcher, command-execution, decision-output, or early-baseline event-order records are reported as concrete provider/event/contract diagnostics, and blocking events require `decision-output` metadata whose provider action is `block` or `deny`
- enforcing plan-only requests run the same fixture readiness and selected-output binding, emit a JSON hook plan, and perform no install lock, release copy, transaction marker, manifest/baseline, ledger, or provider config writes
- install manifest and protected install baseline include selected `fixture_manifest_records` summaries with provider, version/build, platform, event, contract kind, contract id, fixture record hash, and fixture manifest hash; discovery installs may contain an empty summary, while enforcing activation requires exact installed-version proof, `unknown-only` proof only when the installed provider version cannot be discovered, or bounded `range` compatibility backed by a fixture-proven version-comparator record. Selected provider output contracts for enforcing blocking events are stored separately in `selected_output_contracts`, and discovery installs keep that list empty.
- managed hook entries are generated through a provider-neutral plan that clears `output_contract_id` for discovery/non-blocking entries and, for enforcing plan-only plus future enforcing activation, binds each blocking `pre-tool-use` and `stop` entry to the selected event-specific output contract for the same provider/logical event before any provider config write
- Codex `PermissionRequest` hook entry is generated only after fixture proof that the event name is accepted, command execution and payload schema are verified, and a selected block/deny output contract exists; enforcing activation fails when an approval-capable permission event cannot be covered
- provider hook config files are protected roots after install
- install manifest is exact-schema, hash-bound, protected as part of the install root, and rejected by uninstall/rollback when malformed or hash-mismatched
- schema and matrix metadata files plus hook-required provider detection helpers are installed as protected runtime files and covered by the install manifest, protected install baseline, active runtime self-check, and rollback verification
- installer holds `state-global.lock/` across the full install transaction, writes and verifies a staged protected-install-baseline candidate before atomic activation, publishes it to shared state after activation, and verifies the active baseline before leaving hooks active
- install/rollback/uninstall mutations append matching global trusted-state ledger records for runtime config, protected config, provider config, install-manifest, install-release, active-runtime-link, installer-marker, installer-backup, and protected-install-baseline changes; final self-check rejects missing ledger coverage before reporting success
- protected `runtime.env` is parsed through whitelist validation and is never shell-sourced
- checked-in protected config templates validate under the same parser used by installed runtime config
- destructive/protected/stub config malformed lines fail closed, while filesystem/network allowlist malformed lines are reported as config errors and cannot create allow evidence
- install rollback restores provider configs, install manifest, runtime config, protected config, install baseline, and active runtime package files or active runtime symlink when post-install baseline verification fails
- legacy active runtime directories are not migrated by the current discovery skeleton; any directory at `<install-root>/active` makes activation fail before provider configs are touched until backup, ledger, and rollback proof exists
- default uninstall first verifies the protected install baseline plus active-runtime-link/target, provider config, and fixture metadata fingerprints, removes only exact manifest-bound hook entries, then rewrites and verifies the install manifest and protected install baseline so removed hooks are not left in trusted metadata
- default uninstall validates managed hook entries and selected output contracts before provider config mutation, then validates the post-filter hook-entry/output-contract plan before writing updated manifest or baseline metadata
- uninstall uses pending transaction markers, empty uninstall `staged_runtime_path`, post-uninstall manifest/baseline candidate hashes, installer-backup ledger coverage, and `uninstall-failed` recovery so hooks fail closed during interrupted deactivation
- install transaction marker phase transitions are hash-verified and no `.pending.json` marker remains after successful activation or uninstall deactivation
- stale `pre-activation` markers are recoverable only after verifying active runtime and config fingerprints still match the pre-activation state; interrupted `rollback-in-progress` markers resume idempotently or refuse with repair guidance
- activation uses atomic individual renames for `<install-root>/active` and provider configs, with crash recovery via pending marker, backup manifest, hook-side install-in-progress blocking, and rollback
- install transaction backup manifest is hash-bound to the pending transaction, including previous install manifest/baseline hashes, runtime config records, and active runtime fingerprints, and rollback or uninstall recovery verifies restored or committed files against it
- rollback verifies every backup blob against the matching backup file record `content_sha256` before changing the pending marker to `rollback-in-progress` or restoring any file
- install root with a space in its path is covered by config-writer tests
- README provider support matrix exists, uses only closed provider-feature status/proof text, and does not claim Codex FDR challenge parity before Phase 7 fixture proof
