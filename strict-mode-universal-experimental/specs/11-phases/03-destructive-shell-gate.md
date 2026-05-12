# Phase 3 — Destructive Shell Gate

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: block dangerous shell commands in both providers.

Deliverables:

- normalized shell command extraction
- shared destructive gate
- `permission-request` destructive/protected gate when provider fixtures require it
- `permission-request` network/filesystem deny-by-default policy when provider fixtures expose those capabilities
- confirmation hash flow
- pending destructive block records created by `pre-tool-use`
- user confirmation detection in `user-prompt-submit`
- exact approval phrase matching for destructive confirmations
- denied-attempt and confirmation audit

Current implementation status:

- The repository currently contains a pure `tools/destructive_gate_lib.rb` classifier with tests for shell parsing, configured destructive patterns, protected roots, write-capable utility target extraction, shell wrapper handling, direct write targets, protected hardlink aliases, runtime executable blocking, and intent-gated `strict-fdr import -- <path>` handling.
- `tools/protected_baseline_lib.rb` now verifies the installed manifest/baseline hashes, active runtime target, current protected file hashes and `dev+inode` tuples, then exports protected roots, protected inode entries, and parsed destructive patterns for the classifier.
- `strict-hook pre-tool-use` now runs the normalizer, protected baseline loader, and destructive classifier after provider proof matches. Discovery installs write hash-bound `hook.preflight.v1` records and return provider-allow; enforcing installs with a selected pre-tool output contract emit the fixture-bound provider block output when the protected/destructive preflight blocks.
- Approval records, transaction locks, confirmation consumption, and permission-request enforcement are still incomplete. Those pieces must land before Phase 3 can be marked fully enforcing-ready across both providers.

Acceptance:

- `rm -rf /`, `DROP TABLE`, `git reset --hard`, `push --force` block
- read-only commands pass
- confirmation hash file is one-shot and cannot be created+used in the same turn
- confirmation consumption happens under lock before provider allow and cannot be reused after crash/delete failure
- direct tool writes to installed strict-mode runtime/state/config roots, including project `.strict-mode/`, are blocked
- protected path matching covers `multi-edit` and path-bearing `other` or unknown write-like tools
- protected path matching resolves symlink/path-traversal targets and protected `dev+inode` hardlink aliases for direct write/edit/patch tools
- dynamic protected-root changes missed by pre-tool matching are detected by integrity verification and block Stop
- shell commands with unprovable write targets are blocked when they could affect protected roots
- provider shell commands cannot execute strict-mode runtime scripts; exact verified `strict-fdr import -- <path>` is the only runtime entrypoint exception
- exact `strict-fdr import -- <path>` is the only allowed provider shell command that may create trusted state-root artifacts, and only after an enforcing hook records the matching trusted import intent
- project opt-out files created during the current turn are ignored
- project opt-out files first appearing after session baseline require explicit later user approval before becoming active
- current opt-out capture in `turn-baseline` cannot promote a newly created opt-out into active state; activation is based on immutable session baseline or exact approval evidence only
- enabled legacy Claude opt-out paths follow the same approval rules
- confirmations, bypasses, and pending opt-out approvals expire after max TTL and are next-user-turn only
- pending approval `next_user_prompt_marker` is based on monotonic `prompt_seq`, so same-prompt and skipped-prompt approvals fail closed
- user-prompt-hook-created confirmations are consumable immediately on retry, while pre-existing files still obey min-age anti-forgery checks
- generic user affirmations do not create destructive confirmations or opt-out approvals
- confirmations, pending records, protected baselines, mutable-state ledger records, prompt sequence/event logs, and tool-intent/permission-decision/tool/edit sequence logs are written only through the session state transaction lock; global bypass/opt-out/destructive audit logs are written only through the global state transaction lock
- destructive pending records are created with matching `destructive-log.jsonl` `blocked` audit records in the same mixed transaction
- previous-turn confirmation and bypass consumption is proven by marker fingerprints plus audit record hashes captured in `turn-baseline`
- unknown or incomplete payload for enforcing write-like, permission, shell, or stop events fails closed outside Phase 0/log-only discovery
- enforcing activation fails when Stop block output is unverified, including Stop self-timeout handling
- provider without verified user prompt extraction has no in-agent destructive approval fallback
- Codex PermissionRequest cannot approve destructive/protected operations outside strict-mode checks
- approval-capable PermissionRequest allow decisions append and verify exact-schema permission decision records before provider allow emission; deny record failures still emit fixture-verified provider deny with `deny-record-failure`
- Codex PermissionRequest denial uses a fixture-verified provider output contract before enforcement is enabled; approval-capable PermissionRequest without verified deny contract fails provider activation rather than permitting risky approvals
- Codex PermissionRequest network and broad filesystem approvals are denied by default unless exact protected allowlist rules apply
- approval hashes are full SHA-256 hex canonical digests and bind to the exact pending record tuple
