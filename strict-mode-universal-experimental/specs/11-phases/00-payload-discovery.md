# Phase 0 — Payload Discovery

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: capture real Claude and Codex hook payload fixtures without enforcing behavior.

Deliverables:

- `strict-hook` in log-only mode
- fixtures for all supported events
- opt-in raw payload capture under the discovery state root for fixture work only; default discovery logging remains hash-only and must not persist raw payloads
- `tools/import-discovery-fixture.rb` for turning duplicate-key-safe captured JSON payload files into checked-in file-backed `payload-schema` fixture records with paired validated `event.normalized.v1` and provider-proof fixture artifacts
- `tools/normalize-event.rb` and `tools/normalized_event_lib.rb` for conservative duplicate-key-safe payload normalization into exact `event.normalized.v1` shape during fixture work
- `tools/validate-decision-contract.rb` and `tools/decision_contract_lib.rb` for duplicate-key-safe `decision.internal.v1` and `decision.provider-output.v1` validation during fixture work
- exact-schema fixture manifest with provider version/build binding, contract ids, fixture file hashes, compatibility range, and manifest hash
- exact provider detection proof artifact for every imported payload fixture
- fixture-proven provider decision-output formats for block, deny, and injection/no-op surfaces that v0 intends to use, hash-bound to `decision.provider-output.v1` metadata
- fixture-proven Codex `PermissionRequest` role in risky tool approval
- fixture-proven Codex `PermissionRequest` allow/deny output format when the event is approval-capable

Acceptance:

- Claude `Stop` fixture captured
- Claude `SubagentStop` fixture captured or proven unavailable for the installed Claude version before the installer may register it
- Codex `Stop` fixture captured
- Claude `PreToolUse` fixture captured for `Bash`, `Write`, `Edit`, `MultiEdit`
- Codex `PreToolUse` fixture captured for shell, apply_patch, exec_command if exposed
- Codex `PermissionRequest` fixture captured or proven irrelevant to risky tool approval
- Codex `PermissionRequest` fixture proves whether the hook can deny an approval request and what output/exit contract performs that denial
- `UserPromptSubmit` fixture proves whether actual user prompt text is available for approval flows and whether injection/additional-context output is supported
- an `event-order` fixture proves a baseline-capable `SessionStart` or `UserPromptSubmit` fires before model tool execution before enforcing activation is allowed
- `turn_id` fixture proof shows whether the field is a per-user-prompt marker or must be treated as untrusted session/thread metadata
- payload fixtures prove closed-enum `tool.kind` and security-critical `tool.write_intent`; unproven write intent remains `unknown`
- normalized event tests prove exact nested event fields, provider/logical-event domains, logical-event mismatch rejection, fail-closed defaults, shell/other write intent as `unknown`, tool write/read/patch classification, permission-request mirroring, cwd/project containment, and network port domain validation
- fixture capture proves redaction/truncation: no full prompt, full source, or secret-like value is written by default
- raw payload capture is explicit through protected `runtime.env` (`STRICT_CAPTURE_RAW_PAYLOADS=1`), refuses provider process-environment enables, refuses truncated payload capture and any provider proof decision other than `match`, writes only under `state/discovery/raw/<provider>/<event>/`, and still keeps JSONL discovery logs hash-only with redacted provider-proof summary diagnostics
- discovery payload buffering uses a fixed bounded cap in the discovery skeleton; provider process environment cannot raise the cap to avoid truncation or make a payload eligible for raw capture
- payload fixture import rejects symlink source paths, duplicate JSON keys, malformed or non-object JSON, logical-event mismatches, unsafe fixture destinations, duplicate contract ids without `--replace`, and existing destination files with different bytes before updating the manifest
- imported `payload-schema` records must hash-bind the raw captured payload fixture, paired normalized-event fixture, and paired provider-proof fixture in `fixture_file_hashes`; the normalized fixture content must pass the shared `event.normalized.v1` validator, the provider-proof content must pass exact provider proof validation with `decision="match"`, and `payload_schema_hash` must bind the raw payload shape, normalized event, and provider proof before the manifest is updated
- provider mismatch, unknown provider indicators, or conflicting provider indicators must reject fixture import before fixture files or manifests are updated
- `tools/validate-fixtures.rb` rejects malformed fixture manifests, duplicate contract ids, empty fixture-file proof sets, unsafe fixture paths, cross-provider fixture references, symlink fixture files, symlink fixture path components, fixture file hash drift, fixture record hash drift, manifest hash drift, invalid compatibility ranges, missing range comparator records, contract-kind hash sentinel mismatches, payload-schema records missing raw/normalized/provider-proof fixture roles, normalized-event regeneration drift, provider-proof regeneration drift, payload-schema hash drift, decision-output records missing exact contract-id provider-output/stdout/stderr/exit-code fixture roles, provider-output event/logical-event drift, effectless block/deny/inject metadata, captured stdout/stderr/exit-code drift, and decision-contract hash drift before any fixture proof can be selected for enforcement
