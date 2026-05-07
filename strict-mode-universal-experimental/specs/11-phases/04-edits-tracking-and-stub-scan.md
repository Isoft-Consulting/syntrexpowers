# Phase 4 — Edits Tracking And Stub Scan

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: detect stubs before write where possible and at stop time always.

Deliverables:

- write/edit/multi-edit normalization
- Codex patch extraction for `apply_patch`
- post-tool edits log
- git dirty snapshot fallback for shell-created edits
- stop-time file scan

Acceptance:

- Claude Write/Edit/MultiEdit stub blocks pre-tool
- Codex `apply_patch` with added TODO blocks pre-tool blocks only when patch extraction is fixture-proven reliable for the installed Codex version
- if Codex patch content extraction is uncertain but target path extraction is verified, stop-time scan blocks before final; if target path extraction is uncertain, enforcing pre-tool activation fails closed under protected-path rules
- current-turn `allow-stub:` additions do not suppress stub findings
- edited changes are logged as provider-scoped JSONL with path, action, and source
- tool invocations are logged as provider-scoped JSONL with tool kind, write intent, and turn id
- pre-tool intents are logged before allowing shell/write-like tools and unresolved current-turn intents block Stop
- direct path-bearing write intents without verified edit records or fallback coverage block Stop
- multi-file patches log every touched path, not only the first path
- delete changes and rename old/new paths remain in FDR scope even when old paths no longer exist to scan
- shell-created git dirty files are discovered before stop checks run
- ignored-file and submodule dirty changes are either covered by trusted edit records or block Stop as untrusted scope
- missing turn baseline blocks Stop when shell or unknown write-like tools ran in a git project
- missing turn baseline also blocks direct path-bearing edit scope when `turn_marker` is absent or unproven
- shell or unknown write-like tools in non-git projects block Stop because v0 has no safe dirty-snapshot fallback there
- current-turn scope fallback uses monotonic log sequence numbers or byte offsets, not wall-clock timestamps alone
- provider `turn_id` is used for current-turn filtering only after per-user-prompt fixture proof
- pre-existing dirty files are not pulled into scope unless their fingerprint/status changed during the turn
- Stop-blocked edited scope cannot disappear across the approval prompt; a later Stop must validate, fix, or exactly bypass that unresolved scope
