# 17. Implementation Readiness

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


This appendix defines how the markdown contracts become executable parser, fixture, and installer work. It is normative for implementation planning, but it does not replace the owning sub-specs. When this file and an owning sub-spec disagree, the owning sub-spec is the source of truth and this registry must be updated in the same edit.

## 17.1 Schema Registry

Every trusted normalized event, JSON, JSONL, marker, manifest, fixture, protected text config, internal decision, and provider decision-output contract must have a stable schema id before implementation. Runtime parsers and tests must refer to the schema id, not to prose-only names.

| Schema id | Owner | Record/file family | Hash field | Required implementation artifact |
|---|---|---|---|---|
| `metadata.schema-registry.v1` | [Implementation Readiness](17-implementation-readiness.md) | `schemas/schema-registry.json` | `registry_hash` | metadata registry parser and markdown parity validator |
| `metadata.schema-profile.v1` | [Implementation Readiness](17-implementation-readiness.md) | `schemas/*.schema.json` | `profile_hash` | schema-profile metadata parser and filename/id binder |
| `metadata.matrix-registry.v1` | [Implementation Readiness](17-implementation-readiness.md) | `matrices/matrix-registry.json` | `registry_hash` | matrix registry parser and markdown parity validator |
| `metadata.matrix-profile.v1` | [Implementation Readiness](17-implementation-readiness.md) | `matrices/*.matrix.json` | `profile_hash` | matrix-profile metadata parser and filename/id binder |
| `event.normalized.v1` | [Normalized Event Contract](04-normalized-event-contract.md) | normalized event JSON passed from provider adapters to shared core | none | normalized event parser, security-critical sentinel validator, path/domain validator |
| `decision.internal.v1` | [Decision Contract](06-decision-contract.md) | internal decision JSON returned by core scripts to `strict-hook` | none | internal decision parser and action/severity/domain validator |
| `decision.provider-output.v1` | [Decision Contract](06-decision-contract.md), [Hook Event Matrix](03-hook-event-matrix.md) | provider-specific emitted allow/block/deny/inject output contracts | `decision_contract_hash` | provider output contract metadata, fixture binder, emission validator |
| `hook.preflight.v1` | [Hook Event Matrix](03-hook-event-matrix.md), [Destructive Gate](08-shared-core/05-destructive-gate.md) | strict-hook discovery `preflight` object | `preflight_hash` | preflight record parser, hash binder, and attempt/trust/decision coupling validator |
| `fixture.manifest.v1` | [Hook Event Matrix](03-hook-event-matrix.md), [Judge Router](09-judge-router.md) | provider fixture manifest and records | `manifest_hash`, `fixture_record_hash` | schema parser, compatibility-range validator, fixture hash validator |
| `config.runtime-env.v1` | [State Layout](07-state-layout.md), [Judge Router](09-judge-router.md) | protected `runtime.env` key/value config | none | protected text parser plus runtime config domain matrix |
| `config.protected-paths.v1` | [Hook Event Matrix](03-hook-event-matrix.md) | `protected-paths.txt` | none | protected text parser and protected path directive validator |
| `config.destructive-patterns.v1` | [Hook Event Matrix](03-hook-event-matrix.md), [Destructive Gate](08-shared-core/05-destructive-gate.md) | `destructive-patterns.txt` | none | protected text parser and destructive pattern compiler validator |
| `config.stub-allowlist.v1` | [Hook Event Matrix](03-hook-event-matrix.md), [Stub Scan](08-shared-core/01-stub-scan.md) | `stub-allowlist.txt` | none | protected text parser and finding digest validator |
| `config.filesystem-read-allowlist.v1` | [Hook Event Matrix](03-hook-event-matrix.md) | `filesystem-read-allowlist.txt` | none | protected text parser and filesystem read allowlist validator |
| `config.network-allowlist.v1` | [Hook Event Matrix](03-hook-event-matrix.md) | `network-allowlist.txt` | none | protected text parser and network allowlist validator |
| `state.ledger.v1` | [State Layout](07-state-layout.md) | `trusted-state-ledger-*`, `trusted-state-ledger-global.jsonl` | `record_hash` | schema parser plus closed scope/writer/target/operation matrix |
| `state.ledger-fingerprint.v1` | [State Layout](07-state-layout.md) | ledger fingerprints, protected baseline fingerprints, edit/artifact fingerprints | none | canonical fingerprint parser with kind-specific field rules |
| `state.checkpoint.v1` | [State Layout](07-state-layout.md) | `checkpoints-*`, `checkpoints-global.jsonl` | `checkpoint_hash`, `record_hash` | checkpoint parser, covered-range validator, and checkpoint ledger binder |
| `state.lock-owner.v1` | [State Layout](07-state-layout.md) | `state-global.lock/`, `state-<provider>-<sid>.lock/` owner records | `owner_hash` | lock owner parser and stale-lock validator |
| `state.sequence.v1` | [State Layout](07-state-layout.md) | `seq-<provider>-<sid>.json` | `sequence_hash` | monotonic sequence parser and log-tail hash validator |
| `state.prompt-sequence.v1` | [State Layout](07-state-layout.md) | `prompt-seq-<provider>-<sid>.json` | `sequence_hash` | prompt sequence parser and prompt-event tail validator |
| `state.prompt-event.v1` | [State Layout](07-state-layout.md) | `prompt-events-<provider>-<sid>.jsonl` | `record_hash` | prompt-event parser and hash-chain validator |
| `state.baseline.v1` | [State Layout](07-state-layout.md) | session, turn, dirty, and protected baselines | `baseline_hash` | baseline parser with kind-specific nested schemas |
| `approval.pending.v1` | [State Layout](07-state-layout.md) | `pending-destructive-*`, `pending-bypass-*`, `pending-optout-*` | `pending_record_hash` | pending approval parser and exact next-prompt marker validator |
| `approval.audit.v1` | [State Layout](07-state-layout.md) | `destructive-log.jsonl`, `bypass-log.jsonl`, `optout-log.jsonl` | `record_hash` | audit parser plus closed log/action/source matrix |
| `approval.marker.v1` | [State Layout](07-state-layout.md) | `confirm-*`, `bypass-*`, consumed tombstones | `marker_hash` | marker parser, tombstone parser, and consumed-audit/ledger binder |
| `tool.intent.v1` | [Record Edit](08-shared-core/03-record-edit.md) | `tool-intents-*` | `intent_hash` | tool-intent parser and pre/post linkage validator |
| `tool.permission-decision.v1` | [Record Edit](08-shared-core/03-record-edit.md) | `permission-decisions-*` | `record_hash` | permission-decision parser and allow/deny domain validator |
| `tool.invocation.v1` | [Record Edit](08-shared-core/03-record-edit.md) | `tools-*` | `record_hash` | tool invocation parser and intent-hash linkage validator |
| `tool.edit.v1` | [Record Edit](08-shared-core/03-record-edit.md) | `edits-*` | `record_hash` | edit parser and current-turn scope validator |
| `fdr.artifact.v1` | [Stop Guard](08-shared-core/04-stop-guard.md) | normalized `json strict-fdr-v1` state-root artifact | nested `imported_artifact_hash` | artifact parser, freshness validator, and finding domain validator |
| `fdr.import-provenance.v1` | [Stop Guard](08-shared-core/04-stop-guard.md) | artifact `import_provenance` object | `imported_artifact_hash` | trusted import provenance parser and argv/source identity validator |
| `fdr.cycle.v1` | [FDR Challenge](08-shared-core/06-fdr-challenge.md) | `fdr-cycles-*` | `record_hash` | FDR cycle parser plus decision/reason/hash sentinel matrix |
| `judge.response.v1` | [Judge Router](09-judge-router.md) | `strict-judge` JSON response | `response_hash` | judge response parser with bounded confidence decimal and reason/verdict coupling |
| `judge.nested-token.v1` | [Judge Router](09-judge-router.md) | `nested-judge-*` token records | `record_hash`, `token_hash` | nested token parser and ancestry/TTL validator |
| `worker.context-pack.v1` | [Bounded Worker Delegation](08-shared-core/11-bounded-worker-delegation.md) | `worker-context-packs-*` | `context_pack_hash` | context-pack parser, scope/path/token-budget validator, and privacy exclusion validator |
| `worker.invocation.v1` | [Bounded Worker Delegation](08-shared-core/11-bounded-worker-delegation.md) | `worker-invocations-*` | `record_hash` | invocation parser, provider-bound model route validator, and context/result hash binder |
| `worker.result.v1` | [Bounded Worker Delegation](08-shared-core/11-bounded-worker-delegation.md) | `strict-worker` JSON result | `result_hash` | result parser, scoped patch/findings validator, and advisory-authority validator |
| `install.manifest.v1` | [State Layout](07-state-layout.md), [Install And Uninstall](10-install-and-uninstall.md) | `install-manifest.json` | `manifest_hash` | install manifest parser and nested managed-hook record validator |
| `install.baseline.v1` | [State Layout](07-state-layout.md), [Install And Uninstall](10-install-and-uninstall.md) | `protected-install-baseline.json` | `baseline_hash` | protected install baseline parser and disk-fingerprint verifier |
| `install.transaction-marker.v1` | [Install And Uninstall](10-install-and-uninstall.md) | install transaction pending/complete markers | `marker_hash` | transaction marker parser and phase-transition validator |
| `install.backup-manifest.v1` | [Install And Uninstall](10-install-and-uninstall.md) | install rollback and uninstall recovery backup manifest | `manifest_hash` | backup manifest parser and restore/recovery-plan validator |

Implementation may split these into multiple source files, but the schema ids must remain stable. If a runtime parser accepts a trusted record whose schema id is not listed here, implementation is incomplete.

## 17.2 Schema Implementation Profiles

The owning sub-specs define the full exact field lists. Implementation readiness requires those field lists to be copied into machine-readable parser metadata keyed by schema id. A schema id that exists only as prose, a regex, or an ad hoc parser branch is not implementation-ready.

| Schema id | Minimum executable profile that must be encoded |
|---|---|
| `metadata.schema-registry.v1` | Exact registry fields `schema_version`, `registry_kind`, `ids`, `generated_from_spec_hash`, and `registry_hash`; `registry_kind="schema"`; sorted unique ids exactly equal the markdown Schema Registry ids; `registry_hash` recomputation; no extra metadata ids or hidden parser-only ids. |
| `metadata.schema-profile.v1` | Exact profile fields `schema_version`, `schema_id`, `owner`, `input_family`, `hash_fields`, `required_fields`, `referenced_terms`, `referenced_details`, `field_profiles`, `field_details`, `enum_families`, `enum_values`, `variant_requirements`, `variant_rules`, `variants`, `variant_details`, `nested_profiles`, `fixture_requirements`, and `profile_hash`; filename `<schema-id>.schema.json` must match `schema_id`; `required_fields` contains only owner-record top-level fields from 17.2.1, while `referenced_terms` contains non-field code terms referenced by this implementation profile; `referenced_details` comes from 17.2.1.1, `field_profiles`, `enum_families`, and `variant_requirements` come from 17.2.2, `field_details` comes from 17.2.2.1, `enum_values` comes from 17.2.3, `variant_rules` comes from 17.2.4, and `variant_details` comes from 17.2.5; profile must include every owner-defined variant/directive/action/nested family named by this sub-spec; `nested_profiles` contains nested schema profile ids only and never matrix ids. |
| `metadata.matrix-registry.v1` | Exact registry fields `schema_version`, `registry_kind`, `ids`, `generated_from_spec_hash`, and `registry_hash`; `registry_kind="matrix"`; sorted unique ids exactly equal the markdown Closed Matrix Registry ids; `registry_hash` recomputation; no extra matrix ids or hidden validator-only ids. |
| `metadata.matrix-profile.v1` | Exact profile fields `schema_version`, `matrix_id`, `owner`, `dimensions`, `allowed_rows`, `forbidden_row_classes`, `fixture_requirements`, and `profile_hash`; filename `<matrix-id>.matrix.json` must match `matrix_id`; profile must encode every matrix dimension, allowed row class, and invalid-combination class named by this sub-spec. |
| `event.normalized.v1` | Exact normalized top-level fields and nested `turn`, `tool`, `permission`, `prompt`, `assistant`, and `raw` objects; provider/logical-event domains; security-critical unknown/fail-closed sentinels; cwd/project path identity rules; path array normalization; permission network/filesystem domains; current-turn assistant text byte/truncation coupling; current-turn extraction privacy rules. |
| `decision.internal.v1` | Exact internal decision fields `schema_version`, `action`, `reason`, `severity`, `additional_context`, and `metadata`; action domain `allow`, `block`, `warn`, `inject`; severity domain `info`, `warning`, `error`, `critical`; unsafe metadata rejection; action-specific required/empty text rules before provider emission. |
| `decision.provider-output.v1` | Exact provider output metadata fields; provider/event/logical-event/action dimensions; stdout/stderr mode and required-field arrays; exact exit-code shape; event and logical-event fixture binding; block/deny/inject observable output signal requirement; block/deny/inject fixture requirement; `decision_contract_hash` recomputation; output contract id binding to fixture manifest and install baseline; self-timeout block output variants; refusal to emit enforcing block/deny/inject output without matching fixture proof. |
| `hook.preflight.v1` | Exact preflight fields `schema_version`, `attempted`, `trusted`, `logical_event`, `decision`, `would_block`, `reason_code`, `reason_hash`, `tool_kind`, `tool_write_intent`, `tool_name_hash`, `command_hash`, `path_list_hash`, `error_count`, `error_hash`, and `preflight_hash`; logical event, decision, reason code, tool kind, and write intent domains; data hash and `preflight_hash` recomputation; not-attempted sentinel fields; untrusted diagnostic sentinel fields; trusted classifier decision coupling; no raw tool command, raw reason, path list, or error text retention. |
| `fixture.manifest.v1` | Top-level manifest fields `schema_version`, `generated_at`, `records`, `manifest_hash`; record fields from the fixture proof contract; `contract_kind` enum; compatibility modes `exact`, `range`, `unknown-only`; fixture-file hash object schema; hash sentinels per contract kind; `judge-invocation` contract records bound to Judge Router prompt delivery, command execution, timeout, state-isolation, and output-shape fixture requirements; `worker-invocation` contract records bound to Bounded Worker Delegation prompt delivery, no-tool sandbox, timeout, output-shape, and state-isolation fixture requirements. |
| `config.runtime-env.v1` | UTF-8 line grammar; blank/comment handling; exact `KEY=VALUE` syntax; duplicate-key rejection; shell syntax rejection; whitelist key domains and integer/bool/model bounds for judge and worker routes; resolution source rules; closed matrix validator `matrix.runtime-config-domain.v1`. |
| `config.protected-paths.v1` | UTF-8 line grammar; line length cap; directives `protect-file` and `protect-tree`; absolute normalized path rules; `/**` grammar suffix handling; symlink, glob, shell syntax, NUL, newline, and trailing slash rejection. |
| `config.destructive-patterns.v1` | UTF-8 line grammar; directives `shell-ere` and `argv-token`; POSIX ERE compile validation; shell-token comparison input rules; no shell sourcing, expansion, or grep/sed/awk shell pass-through. |
| `config.stub-allowlist.v1` | UTF-8 line grammar; directive `finding`; full lowercase SHA-256 finding digest validation; previous-baseline or approved-bypass activation requirement; line-number-only identity rejection. |
| `config.filesystem-read-allowlist.v1` | UTF-8 line grammar; directives `read` and `read-tree`; absolute normalized path rules; `/**` grammar suffix handling; protected-root and protected `dev+inode` rejection; no write/execute/delete/chmod allowlisting. |
| `config.network-allowlist.v1` | UTF-8 line grammar; `connect http|https host port` tuple; canonical lower-case IDNA A-label or literal IP host; port `1..65535`; wildcard, CIDR, userinfo, path/query/fragment, proxy, tunnel, listener, and environment-derived host rejection. |
| `state.ledger.v1` | Exact ledger fields; `ledger_scope`, `writer`, `target_class`, and `operation` enums; required tuple presence by scope; `old_fingerprint` and `new_fingerprint` using `state.ledger-fingerprint.v1`; `related_record_hash` owner rules including 64-zero sentinel for checkpoint operations; `previous_record_hash` chain; closed matrix validator `matrix.ledger-scope-writer-target-operation.v1`. |
| `state.ledger-fingerprint.v1` | Exact fingerprint object fields; `exists` and `kind` coupling; missing/file/directory/symlink field sentinels; symlink `readlink` hashing; directory `tree_hash` only where an owner schema names a sorted child-record input; active-runtime-link restriction to lexical `<install-root>/active`. |
| `state.checkpoint.v1` | Exact checkpoint fields; checkpoint scope tuple with full tuple required for session checkpoints and empty tuple required for global checkpoints; checkpointed file path/kind; closed checkpointed-kind enum excluding baselines, approval audit logs, consumed tombstones, and FDR artifacts; covered sequence range; covered byte range; last covered record hash; source ledger record hash; retained successor record hash; source ledger binding to an already chained `writer="repair"`, `operation="checkpoint"` ledger record with checkpointable target class, 64-zero `related_record_hash`, and old/new fingerprints matching compaction; `checkpoint_hash` and `record_hash` recomputation; rejection when any pending approval/import/challenge or unresolved blocked Stop scope still references covered evidence. |
| `state.lock-owner.v1` | Exact owner fields; `lock_scope` enum; full tuple required for session locks; empty tuple required for ordinary global locks; `transaction_kind` enum; non-negative pid rules; `owner_hash` recomputation; stale-lock repair eligibility separate from parser validity. |
| `state.sequence.v1` | Exact sequence fields; monotonic counters for tool-intent, permission-decision, tool, and edit domains; last sequence/hash binding to the corresponding logs; `sequence_hash` recomputation; regression and duplicate detection. |
| `state.prompt-sequence.v1` | Exact prompt sequence fields; non-negative `last_prompt_seq`; `last_prompt_event_hash` zero sentinel for no events; prompt-event tail binding; `sequence_hash` recomputation. |
| `state.prompt-event.v1` | Exact prompt-event fields; monotonic `prompt_seq`; tuple binding; redacted payload hash; `previous_record_hash` chain; first-record zero sentinel. |
| `state.baseline.v1` | Exact common baseline fields plus `session`, `turn`, `dirty`, and `protected` variants; nested `log_offsets`, `last_sequences`, `last_safe_stop_sequences`, `approval_evidence`, project opt-out fingerprints, dirty path records, protected file records, and allow-side audit batch hash input. |
| `approval.pending.v1` | Common pending fields plus `destructive-confirm`, `quality-bypass`, and `optout-approval` variant fields; filename `approval_hash` binding; `next_user_prompt_marker` grammar; TTL fields; `pending_record_hash` recomputation; ledger coverage. |
| `approval.audit.v1` | Common audit fields; log-specific extra fields; consumed and resolved extra field sets; `previous_record_hash` chain; `prompt_seq` rules by source; closed matrix validator `matrix.approval-log-action-source.v1`. |
| `approval.marker.v1` | Exact marker fields; destructive and quality-bypass `kind` variants; source fixed to `user-prompt-hook`; marker filename/hash binding; consumed tombstone as preserved marker bytes; consumed audit and ledger relation validation. |
| `tool.intent.v1` | Exact tool-intent fields; `logical_event`, `tool_kind`, `command_hash_source`, and `write_intent` domains; canonical path list schema; payload hash input; `intent_hash` recomputation; unresolved-intent fail-closed rules. |
| `tool.permission-decision.v1` | Exact permission-decision fields; `permission_operation`, `requested_tool_kind`, `decision`, and `reason_code` domains; path and network tuple schemas; allow/deny unknown-sentinel restrictions; `previous_record_hash` chain; closed matrix validator `matrix.permission-decision-domain.v1`. |
| `tool.invocation.v1` | Exact tool invocation fields; pre-tool intent seq/hash linkage; command hash source parity with the intent record; write-intent and payload-hash parity; `record_hash` recomputation. |
| `tool.edit.v1` | Exact edit fields; `action` and `source` domains; path/old_path/new_path relation by action; turn marker semantics; deleted and rename-old path retention for FDR scope; `record_hash` recomputation. |
| `fdr.artifact.v1` | Exact `json strict-fdr-v1` top-level fields; coverage cutoff/list/min/max/log-digest coupling; edited/deleted/renamed path object variants; finding schema and verdict/finding-count coupling; `import_provenance` using `fdr.import-provenance.v1`; normalized artifact hash recomputation. |
| `fdr.import-provenance.v1` | Exact provenance fields; trusted argv shape `[<install-root>/active/bin/strict-fdr, "import", "--", <source-path>]`; `command_hash_source="trusted-import-argv"`; source identity fingerprint; import intent seq/hash linkage; coverage cutoffs equal top-level artifact cutoffs. |
| `fdr.cycle.v1` | Exact FDR cycle fields; artifact state/value coupling; decision-specific `challenge_reason`; prompt/response/original/bypass hash sentinels; cycle index/max-cycle rules; `previous_record_hash` chain; closed matrix validator `matrix.fdr-cycle-decision-reason.v1`. |
| `judge.response.v1` | Exact response fields; verdict enum; closed reason enum coupled to verdict; finding schema for challenge only; confidence canonical decimal `0..1` with at most three fractional digits; model/backend binding; scope/artifact hash equality; `response_hash` recomputation. |
| `judge.nested-token.v1` | Exact nested token fields; nonce hash input; provider/session/raw-session/cwd/project tuple; parent process identity; allowed child pid update rules; TTL shorter than judge timeout and no longer than 120 seconds; ledger coverage. |
| `worker.context-pack.v1` | Exact context pack fields; provider session cwd project tuple; task kind, expected output kind, and model route intent domains; allowed path list; source fragment bounds; constraint list; token budget bounds; raw transcript and provider history exclusion; scope digest binding; `context_pack_hash` recomputation. |
| `worker.invocation.v1` | Exact invocation fields; provider session cwd project tuple; backend and model route domain; task kind and allowed output kind domains; context, prompt, input, selected source paths, output, result, and record hash binding; timeout and completion state bounds; decision and reason coupling; provider-bound route enforcement; previous record hash chain; advisory-only authority. |
| `worker.result.v1` | Exact result fields; provider, task, output, and backend domains; invocation, context, and scope hash equality; patch and finding object bounds; `advisory_only` must be true; clean-or-allow authority claims rejected; confidence canonical decimal 0..1 with at most three fractional digits; `result_hash` recomputation. |
| `install.manifest.v1` | Exact install manifest top-level fields; managed hook entry schema; managed hook command grammar and lexical `<install-root>/active/bin/strict-hook` binding; removal selector schema; runtime/config/provider/protected file record schemas; fixture manifest record schema; selected output contract schema; generated command/env derivation; duplicate selector/path tuple rejection. |
| `install.baseline.v1` | Exact protected install baseline fields; managed hook entries matching manifest; selected output contracts matching manifest; active runtime lexical/resolved path distinction; managed hook command grammar and lexical `<install-root>/active/bin/strict-hook` binding; protected inode index schema; generated timeout/env proof; current disk fingerprint verification. |
| `install.transaction-marker.v1` | Exact marker fields; install, rollback, and uninstall phase enum; `.pending.json` versus `.complete.json` phase restrictions; install versus uninstall staged-field semantics including empty uninstall `staged_runtime_path` and post-uninstall manifest/baseline candidate hashes; previous manifest/baseline hash zero sentinels; phase-transition hash rewrite; pending filename/install-root/state-root binding; completed-pending cleanup with phase validation before repair, complete-marker ledger repair, pending-delete ledger repair, cross-writer ledger mismatch refusal, complete-only create-writer binding to latest pending writer, non-noop pending-delete preimage requirement, and phase-derived writer attribution; rollback and uninstall recovery eligibility fields. |
| `install.backup-manifest.v1` | Exact backup manifest fields; previous active runtime fingerprint variants; provider/protected/runtime config record schemas; backup file record schema; `existed` and `backup_relative_path` coupling; install rollback and uninstall recovery hash binding. |

### 17.2.1 Schema Required Field Lists

`required_fields` names only top-level fields physically owned by the schema record. It must not include enum values, filename templates, external schema ids, external matrix ids, nested-object member names, hash-binding terms from related records, or provider output keys. Non-field code terms referenced by the implementation profile remain in `referenced_terms`.

| Schema id | Required top-level fields |
|---|---|
| `metadata.schema-registry.v1` | `schema_version`, `registry_kind`, `ids`, `generated_from_spec_hash`, `registry_hash` |
| `metadata.schema-profile.v1` | `schema_version`, `schema_id`, `owner`, `input_family`, `hash_fields`, `required_fields`, `referenced_terms`, `referenced_details`, `field_profiles`, `field_details`, `enum_families`, `enum_values`, `variant_requirements`, `variant_rules`, `variants`, `variant_details`, `nested_profiles`, `fixture_requirements`, `profile_hash` |
| `metadata.matrix-registry.v1` | `schema_version`, `registry_kind`, `ids`, `generated_from_spec_hash`, `registry_hash` |
| `metadata.matrix-profile.v1` | `schema_version`, `matrix_id`, `owner`, `dimensions`, `allowed_rows`, `forbidden_row_classes`, `fixture_requirements`, `profile_hash` |
| `event.normalized.v1` | `schema_version`, `provider`, `logical_event`, `raw_event`, `session_id`, `parent_session_id`, `turn_id`, `cwd`, `project_dir`, `transcript_path`, `turn`, `tool`, `permission`, `prompt`, `assistant`, `raw` |
| `decision.internal.v1` | `schema_version`, `action`, `reason`, `severity`, `additional_context`, `metadata` |
| `decision.provider-output.v1` | `schema_version`, `contract_id`, `provider`, `event`, `logical_event`, `provider_action`, `stdout_mode`, `stdout_required_fields`, `stderr_mode`, `stderr_required_fields`, `exit_code`, `blocks_or_denies`, `injects_context`, `decision_contract_hash` |
| `hook.preflight.v1` | `schema_version`, `attempted`, `trusted`, `logical_event`, `decision`, `would_block`, `reason_code`, `reason_hash`, `tool_kind`, `tool_write_intent`, `tool_name_hash`, `command_hash`, `path_list_hash`, `error_count`, `error_hash`, `preflight_hash` |
| `fixture.manifest.v1` | `schema_version`, `generated_at`, `records`, `manifest_hash` |
| `config.runtime-env.v1` | none |
| `config.protected-paths.v1` | none |
| `config.destructive-patterns.v1` | none |
| `config.stub-allowlist.v1` | none |
| `config.filesystem-read-allowlist.v1` | none |
| `config.network-allowlist.v1` | none |
| `state.ledger.v1` | `schema_version`, `ledger_scope`, `writer`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `target_path`, `target_class`, `operation`, `old_fingerprint`, `new_fingerprint`, `related_record_hash`, `ts`, `previous_record_hash`, `record_hash` |
| `state.ledger-fingerprint.v1` | `exists`, `kind`, `dev`, `inode`, `mode`, `size_bytes`, `mtime_ns`, `content_sha256`, `link_target`, `tree_hash` |
| `state.checkpoint.v1` | `schema_version`, `checkpoint_scope`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `checkpointed_path`, `checkpointed_kind`, `covered_seq_min`, `covered_seq_max`, `covered_byte_min`, `covered_byte_max`, `last_covered_record_hash`, `retained_successor_record_hash`, `source_ledger_record_hash`, `created_at`, `checkpoint_hash`, `previous_record_hash`, `record_hash` |
| `state.lock-owner.v1` | `schema_version`, `lock_scope`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `transaction_kind`, `pid`, `process_start`, `created_at`, `timeout_at`, `owner_hash` |
| `state.sequence.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `last_seq_by_record_type`, `last_record_hash_by_record_type`, `created_at`, `updated_at`, `sequence_hash` |
| `state.prompt-sequence.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `last_prompt_seq`, `last_prompt_event_hash`, `created_at`, `updated_at`, `sequence_hash` |
| `state.prompt-event.v1` | `schema_version`, `prompt_seq`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `payload_hash`, `ts`, `previous_record_hash`, `record_hash` |
| `state.baseline.v1` | `schema_version`, `kind`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `created_at`, `updated_at`, `baseline_hash` |
| `approval.pending.v1` | `schema_version`, `kind`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `approval_hash`, `created_at`, `expires_at`, `next_user_prompt_marker`, `pending_record_hash` |
| `approval.audit.v1` | `schema_version`, `log`, `action`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `approval_hash`, `pending_record_hash`, `next_user_prompt_marker`, `prompt_seq`, `source`, `ts`, `previous_record_hash`, `record_hash` |
| `approval.marker.v1` | `schema_version`, `kind`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `approval_hash`, `pending_record_hash`, `next_user_prompt_marker`, `approval_prompt_seq`, `approval_log_record_hash`, `source`, `created_at`, `expires_at`, `marker_hash` |
| `tool.intent.v1` | `schema_version`, `seq`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `logical_event`, `tool_kind`, `tool_name`, `normalized_command_hash`, `command_hash_source`, `normalized_path_list`, `payload_hash`, `write_intent`, `ts`, `intent_hash` |
| `tool.permission-decision.v1` | `schema_version`, `seq`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `logical_event`, `permission_operation`, `requested_tool_kind`, `decision`, `reason_code`, `normalized_path_list`, `network_tuple_list`, `payload_hash`, `ts`, `previous_record_hash`, `record_hash` |
| `tool.invocation.v1` | `schema_version`, `seq`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `tool_kind`, `tool_name`, `command_hash`, `command_hash_source`, `write_intent`, `payload_hash`, `pre_tool_intent_seq`, `pre_tool_intent_hash`, `ts`, `record_hash` |
| `tool.edit.v1` | `schema_version`, `seq`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `path`, `old_path`, `new_path`, `action`, `source`, `ts`, `record_hash` |
| `fdr.artifact.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `review_generated_at`, `imported_at`, `turn_marker`, `coverage_cutoff_tool_intent_seq`, `coverage_cutoff_tool_seq`, `coverage_cutoff_edit_seq`, `tool_intent_seq_min`, `tool_intent_seq_max`, `tool_intent_seq_list`, `tool_intent_log_digest`, `tool_seq_min`, `tool_seq_max`, `tool_seq_list`, `tool_log_digest`, `edit_seq_min`, `edit_seq_max`, `edit_seq_list`, `edit_log_digest`, `edited_paths`, `deleted_paths`, `renamed_paths`, `findings`, `finding_count`, `verdict`, `reviewer`, `import_provenance` |
| `fdr.import-provenance.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `source_path`, `source_realpath`, `source_fingerprint`, `source_size_bytes`, `argv`, `command_hash`, `command_hash_source`, `import_intent_seq`, `import_intent_hash`, `imported_artifact_hash`, `coverage_cutoff_tool_intent_seq`, `coverage_cutoff_tool_seq`, `coverage_cutoff_edit_seq` |
| `fdr.cycle.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `turn_marker`, `cycle_index`, `max_cycles`, `scope_digest`, `tool_intent_seq_list`, `tool_seq_list`, `edit_seq_list`, `tool_intent_log_digest`, `tool_log_digest`, `edit_log_digest`, `content_scope_fingerprint_digest`, `artifact_state`, `artifact_hash`, `artifact_verdict`, `finding_count`, `challenge_reason`, `judge_backend`, `judge_model`, `prompt_hash`, `response_hash`, `decision`, `original_challenge_record_hash`, `bypass_marker_hash`, `bypass_consumed_record_hash`, `bypass_ledger_record_hash`, `ts`, `previous_record_hash`, `record_hash` |
| `judge.response.v1` | `schema_version`, `verdict`, `reason`, `findings`, `reviewed_scope_digest`, `reviewed_artifact_hash`, `confidence`, `model`, `backend`, `response_hash` |
| `judge.nested-token.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `judge_backend`, `judge_model`, `parent_pid`, `parent_process_start`, `allowed_child_pid`, `created_at`, `expires_at`, `token_hash`, `record_hash` |
| `worker.context-pack.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `task_kind`, `scope_digest`, `allowed_paths`, `source_fragments`, `constraints`, `expected_output_kind`, `model_route_intent`, `input_token_budget`, `created_at`, `context_pack_hash` |
| `worker.invocation.v1` | `schema_version`, `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `worker_backend`, `worker_model`, `task_kind`, `scope_digest`, `context_pack_hash`, `prompt_hash`, `input_hash`, `selected_source_paths_hash`, `allowed_output_kind`, `timeout_ms`, `output_hash`, `result_hash`, `decision`, `reason`, `started_at`, `completed_at`, `previous_record_hash`, `record_hash` |
| `worker.result.v1` | `schema_version`, `provider`, `task_kind`, `scope_digest`, `context_pack_hash`, `invocation_record_hash`, `output_kind`, `patch`, `findings`, `notes`, `confidence`, `model`, `backend`, `advisory_only`, `result_hash` |
| `install.manifest.v1` | `schema_version`, `transaction_id`, `install_root`, `active_runtime_link`, `active_runtime_target`, `state_root`, `config_root`, `package_version`, `managed_hook_entries`, `runtime_file_records`, `runtime_config_records`, `provider_config_records`, `protected_config_records`, `fixture_manifest_records`, `selected_output_contracts`, `created_at`, `updated_at`, `manifest_hash` |
| `install.baseline.v1` | `schema_version`, `kind`, `transaction_id`, `install_root`, `active_runtime_link`, `active_runtime_target`, `state_root`, `config_root`, `provider_config_paths`, `managed_hook_entries`, `generated_hook_commands`, `generated_hook_env`, `package_version`, `install_manifest_hash`, `runtime_file_records`, `runtime_config_records`, `provider_config_records`, `protected_config_records`, `fixture_manifest_records`, `selected_output_contracts`, `protected_file_inode_index`, `created_at`, `updated_at`, `baseline_hash` |
| `install.transaction-marker.v1` | `schema_version`, `transaction_id`, `phase`, `install_root`, `state_root`, `staged_runtime_path`, `previous_active_runtime_path`, `previous_install_manifest_hash`, `previous_install_baseline_hash`, `backup_manifest_hash`, `staged_install_manifest_hash`, `staged_install_baseline_hash`, `provider_config_plan_hash`, `created_at`, `updated_at`, `marker_hash` |
| `install.backup-manifest.v1` | `schema_version`, `transaction_id`, `created_at`, `install_root`, `state_root`, `previous_active_runtime_path`, `previous_active_runtime_kind`, `previous_active_runtime_fingerprint`, `previous_install_manifest_hash`, `previous_install_baseline_hash`, `provider_config_records`, `protected_config_records`, `runtime_config_records`, `backup_file_records`, `manifest_hash` |

### 17.2.1.1 Schema Referenced Term Details

Every referenced term derived from the implementation profile in 17.2 must have exactly one row here. `referenced_details` stores each term as a kind, source, and rule array so generated parser fixtures can distinguish external schema ids, matrix ids, grammar literals, enum literals, numeric bounds, filename templates, and hash-binding terms. `referenced_details` keys must exactly match `referenced_terms`.

| Schema id | Referenced term | Kind | Source | Rules |
|---|---|---|---|---|
| `metadata.schema-registry.v1` | `registry_kind="schema"` | `registry-literal` | `metadata-bootstrap` | registry_kind must equal schema |
| `metadata.schema-profile.v1` | `<schema-id>.schema.json` | `filename-template` | `metadata-bootstrap` | filename stem binds schema_id |
| `metadata.matrix-registry.v1` | `registry_kind="matrix"` | `registry-literal` | `metadata-bootstrap` | registry_kind must equal matrix |
| `metadata.matrix-profile.v1` | `<matrix-id>.matrix.json` | `filename-template` | `metadata-bootstrap` | filename stem binds matrix_id |
| `decision.internal.v1` | `allow` | `enum-literal` | `decision action domain` | action literal |
| `decision.internal.v1` | `block` | `enum-literal` | `decision action domain` | action literal |
| `decision.internal.v1` | `warn` | `enum-literal` | `decision action domain` | action literal |
| `decision.internal.v1` | `inject` | `enum-literal` | `decision action domain` | action literal |
| `decision.internal.v1` | `info` | `enum-literal` | `decision severity domain` | severity literal |
| `decision.internal.v1` | `warning` | `enum-literal` | `decision severity domain` | severity literal |
| `decision.internal.v1` | `error` | `enum-literal` | `decision severity domain` | severity literal |
| `decision.internal.v1` | `critical` | `enum-literal` | `decision severity domain` | severity literal |
| `fixture.manifest.v1` | `contract_kind` | `field-reference` | `fixture proof contract` | record field controls hash sentinels |
| `fixture.manifest.v1` | `exact` | `enum-literal` | `compatibility range mode` | exact compatibility mode |
| `fixture.manifest.v1` | `range` | `enum-literal` | `compatibility range mode` | range compatibility mode |
| `fixture.manifest.v1` | `unknown-only` | `enum-literal` | `compatibility range mode` | unknown-only compatibility mode |
| `fixture.manifest.v1` | `judge-invocation` | `enum-literal` | `contract kind domain` | judge invocation proof contract |
| `fixture.manifest.v1` | `worker-invocation` | `enum-literal` | `contract kind domain` | bounded worker invocation proof contract |
| `config.runtime-env.v1` | `KEY=VALUE` | `line-grammar` | `runtime env parser` | exact assignment grammar |
| `config.runtime-env.v1` | `matrix.runtime-config-domain.v1` | `matrix-id` | `closed matrix registry` | runtime config domain validator |
| `config.protected-paths.v1` | `protect-file` | `directive-literal` | `protected paths parser` | file protection directive |
| `config.protected-paths.v1` | `protect-tree` | `directive-literal` | `protected paths parser` | tree protection directive |
| `config.protected-paths.v1` | `/**` | `grammar-token` | `protected paths parser` | tree suffix grammar |
| `config.destructive-patterns.v1` | `shell-ere` | `directive-literal` | `destructive patterns parser` | POSIX ERE directive |
| `config.destructive-patterns.v1` | `argv-token` | `directive-literal` | `destructive patterns parser` | literal argv-token directive |
| `config.stub-allowlist.v1` | `finding` | `directive-literal` | `stub allowlist parser` | finding digest directive |
| `config.filesystem-read-allowlist.v1` | `read` | `directive-literal` | `filesystem read allowlist parser` | file read directive |
| `config.filesystem-read-allowlist.v1` | `read-tree` | `directive-literal` | `filesystem read allowlist parser` | tree read directive |
| `config.filesystem-read-allowlist.v1` | `/**` | `grammar-token` | `filesystem read allowlist parser` | tree suffix grammar |
| `config.filesystem-read-allowlist.v1` | `dev+inode` | `identity-token` | `filesystem read allowlist parser` | protected inode rejection identity |
| `config.network-allowlist.v1` | `connect http|https host port` | `line-grammar` | `network allowlist parser` | connect tuple grammar |
| `config.network-allowlist.v1` | `1..65535` | `numeric-bound` | `network allowlist parser` | allowed TCP port range |
| `state.ledger.v1` | `state.ledger-fingerprint.v1` | `schema-id` | `schema registry` | nested fingerprint schema |
| `state.ledger.v1` | `matrix.ledger-scope-writer-target-operation.v1` | `matrix-id` | `closed matrix registry` | ledger domain validator |
| `state.ledger-fingerprint.v1` | `readlink` | `syscall-reference` | `ledger fingerprint parser` | symlink target hash input |
| `state.ledger-fingerprint.v1` | `<install-root>/active` | `path-template` | `install layout` | active runtime lexical path |
| `state.checkpoint.v1` | `writer="repair"` | `binding-literal` | `ledger checkpoint binding` | source ledger writer requirement |
| `state.checkpoint.v1` | `operation="checkpoint"` | `binding-literal` | `ledger checkpoint binding` | source ledger operation requirement |
| `state.checkpoint.v1` | `related_record_hash` | `hash-binding` | `ledger checkpoint binding` | ledger related hash zero sentinel |
| `state.baseline.v1` | `session` | `enum-literal` | `baseline kind domain` | session baseline variant |
| `state.baseline.v1` | `turn` | `enum-literal` | `baseline kind domain` | turn baseline variant |
| `state.baseline.v1` | `dirty` | `enum-literal` | `baseline kind domain` | dirty baseline variant |
| `state.baseline.v1` | `protected` | `enum-literal` | `baseline kind domain` | protected baseline variant |
| `state.baseline.v1` | `log_offsets` | `nested-field-reference` | `baseline nested profiles` | log offset nested family |
| `state.baseline.v1` | `last_sequences` | `nested-field-reference` | `baseline nested profiles` | sequence nested family |
| `state.baseline.v1` | `last_safe_stop_sequences` | `nested-field-reference` | `baseline nested profiles` | safe stop sequence nested family |
| `state.baseline.v1` | `approval_evidence` | `nested-field-reference` | `baseline nested profiles` | approval evidence nested family |
| `approval.pending.v1` | `destructive-confirm` | `enum-literal` | `approval pending kind domain` | destructive pending variant |
| `approval.pending.v1` | `quality-bypass` | `enum-literal` | `approval pending kind domain` | quality bypass pending variant |
| `approval.pending.v1` | `optout-approval` | `enum-literal` | `approval pending kind domain` | opt-out pending variant |
| `approval.audit.v1` | `matrix.approval-log-action-source.v1` | `matrix-id` | `closed matrix registry` | approval audit matrix validator |
| `approval.marker.v1` | `user-prompt-hook` | `hook-source` | `approval marker parser` | fixed marker source |
| `tool.permission-decision.v1` | `matrix.permission-decision-domain.v1` | `matrix-id` | `closed matrix registry` | permission decision matrix validator |
| `fdr.artifact.v1` | `json strict-fdr-v1` | `artifact-format` | `FDR artifact parser` | strict FDR JSON format marker |
| `fdr.artifact.v1` | `fdr.import-provenance.v1` | `schema-id` | `schema registry` | nested import provenance schema |
| `fdr.import-provenance.v1` | `[<install-root>/active/bin/strict-fdr, "import", "--", <source-path>]` | `argv-shape` | `trusted import command` | exact trusted import argv |
| `fdr.import-provenance.v1` | `command_hash_source="trusted-import-argv"` | `binding-literal` | `trusted import command` | command hash source requirement |
| `fdr.cycle.v1` | `matrix.fdr-cycle-decision-reason.v1` | `matrix-id` | `closed matrix registry` | FDR cycle decision matrix validator |
| `judge.response.v1` | `0..1` | `numeric-bound` | `judge response parser` | confidence inclusive decimal range |
| `install.manifest.v1` | `<install-root>/active/bin/strict-hook` | `path-template` | `managed hook command parser` | lexical active hook command path |
| `install.baseline.v1` | `<install-root>/active/bin/strict-hook` | `path-template` | `managed hook command parser` | lexical active hook command path |
| `install.transaction-marker.v1` | `.pending.json` | `filename-suffix` | `installer marker files` | unsettled marker suffix |
| `install.transaction-marker.v1` | `.complete.json` | `filename-suffix` | `installer marker files` | complete marker suffix |
| `install.backup-manifest.v1` | `existed` | `field-reference` | `backup manifest parser` | backup record existence discriminator |
| `install.backup-manifest.v1` | `backup_relative_path` | `field-reference` | `backup manifest parser` | backup record path field |

### 17.2.2 Schema Structured Profile Details

`field_profiles`, `enum_families`, and `variant_requirements` are bootstrap metadata, not a full JSON Schema dialect. They expose the nested field groups, closed enum families, and variant-specific required-field rules that parser tests must cover. `referenced_details`, `field_details`, `enum_values`, `variant_rules`, and `variant_details` add detail records for compact lists. A cell value of `none` means the schema has no additional structured item in that category.

| Schema id | Field profiles | Enum families | Variant requirements |
|---|---|---|---|
| `metadata.schema-registry.v1` | none | `registry_kind` | `schema` registry kind |
| `metadata.schema-profile.v1` | `hash_fields`; `required_fields`; `referenced_terms`; `referenced_details`; `field_profiles`; `field_details`; `enum_families`; `enum_values`; `variant_requirements`; `variant_rules`; `variants`; `variant_details`; `nested_profiles`; `fixture_requirements` | none | filename `schema_id` binding; `nested_profiles` excludes matrix ids |
| `metadata.matrix-registry.v1` | none | `registry_kind` | `matrix` registry kind |
| `metadata.matrix-profile.v1` | `dimensions`; `allowed_rows`; `forbidden_row_classes`; `fixture_requirements` | none | filename `matrix_id` binding |
| `event.normalized.v1` | `turn`; `tool`; `tool.file_changes`; `permission`; `permission.filesystem`; `permission.network`; `prompt`; `assistant`; `raw` | `provider`; `logical_event`; `tool.kind`; `tool.write_intent`; `tool.file_changes.action`; `tool.file_changes.source`; `permission.operation`; `permission.access_mode`; `permission.requested_tool_kind`; `permission.filesystem.access_mode`; `permission.filesystem.recursive`; `permission.filesystem.scope`; `permission.network.scheme`; `permission.network.operation`; `permission.can_approve`; `turn.assistant_text_truncated` | permission-request mirror fields; current-turn assistant text byte and truncation coupling; unknown sentinel fail-closed fields |
| `decision.internal.v1` | `metadata` | `action`; `severity` | `allow` empty text; `warn` warning text; `block` reason text; `inject` context text |
| `decision.provider-output.v1` | `stdout_required_fields`; `stderr_required_fields` | `provider`; `provider_action`; `stdout_mode`; `stderr_mode` | JSON modes require sorted required-field arrays; block or deny sets `blocks_or_denies`; inject sets `injects_context`; block/deny/inject observable signal |
| `hook.preflight.v1` | data hash fields; tool summary fields; error diagnostic fields | `logical_event`; `decision`; `reason_code`; `tool_kind`; `tool_write_intent` | not-attempted sentinel fields; untrusted diagnostic sentinel fields; trusted classifier decision coupling |
| `fixture.manifest.v1` | `records`; `records.fixture_file_hashes`; `records.compatibility_range` | `provider`; `contract_kind`; `compatibility_range.mode` | hash sentinel fields by contract kind; exact compatibility range; range compatibility comparator |
| `config.runtime-env.v1` | runtime config lines; integer bounds | runtime key; boolean value; claude judge model; codex judge model; claude worker model; codex worker model | key-specific value parser and safe fallback behavior |
| `config.protected-paths.v1` | directive lines | directive kind | `protect-file` file target; `protect-tree` tree target |
| `config.destructive-patterns.v1` | directive lines | directive kind | `shell-ere` compile validation; `argv-token` token comparison |
| `config.stub-allowlist.v1` | directive lines | directive kind | `finding` digest identity |
| `config.filesystem-read-allowlist.v1` | directive lines | directive kind | `read` file target; `read-tree` tree target |
| `config.network-allowlist.v1` | network allowlist lines | protocol; operation | `connect` host and port tuple |
| `state.ledger.v1` | `old_fingerprint`; `new_fingerprint` | `ledger_scope`; `writer`; `target_class`; `operation` | session tuple required; global tuple empty unless approval-tied; checkpoint related hash zero sentinel |
| `state.ledger-fingerprint.v1` | none | `exists`; `kind` | missing sentinel fields; file content hash; directory tree hash; symlink link target hash |
| `state.checkpoint.v1` | none | `checkpoint_scope`; `checkpointed_kind` | session tuple required; global tuple empty; retained successor zero sentinel; source ledger checkpoint binding |
| `state.lock-owner.v1` | none | `lock_scope`; `transaction_kind` | session lock tuple required; ordinary global lock tuple empty; stale lock repair eligibility |
| `state.sequence.v1` | `last_seq_by_record_type`; `last_record_hash_by_record_type` | record type domain | zero sequence hash sentinel; monotonic counter binding |
| `state.prompt-sequence.v1` | none | none | zero prompt-event hash sentinel; prompt-event tail binding |
| `state.prompt-event.v1` | none | none | first prompt-event previous hash zero sentinel; prompt sequence monotonicity |
| `state.baseline.v1` | `log_offsets`; `last_sequences`; `last_safe_stop_sequences`; `approval_evidence`; `project_optouts_previous`; `project_optouts_current`; `dirty path records`; `submodule_records`; `dirty_limits`; `protected file records`; `protected inode index` | `kind`; dirty path status; project opt-out source | session baseline extras; turn baseline extras; dirty baseline extras; protected baseline extras |
| `approval.pending.v1` | `gate_context`; `optout_fingerprint` | `kind`; `command_hash_source`; `optout_kind` | destructive-confirm extra fields; quality-bypass extra fields; optout-approval extra fields |
| `approval.audit.v1` | consumed marker fingerprints; resolved quality scope fields; opt-out fingerprint fields | `log`; `action`; `source`; `command_hash_source`; `optout_kind` | destructive action fields; bypass action fields; opt-out action fields; consumed extra fields; resolved extra fields |
| `approval.marker.v1` | none | `kind`; `source` | destructive marker fields; quality-bypass marker fields; consumed tombstone preserves marker bytes |
| `tool.intent.v1` | `normalized_path_list` | `logical_event`; `tool_kind`; `command_hash_source`; `write_intent` | command absent zero hash; write intent classification; payload hash input |
| `tool.permission-decision.v1` | `normalized_path_list`; `network_tuple_list`; `network_tuple_list entries` | `permission_operation`; `requested_tool_kind`; `decision`; `reason_code` | allow path entries must be absolute; deny may use unknown sentinel; first previous hash zero sentinel |
| `tool.invocation.v1` | none | `tool_kind`; `command_hash_source`; `write_intent` | pre-tool intent linkage; command hash parity; payload hash parity |
| `tool.edit.v1` | none | `action`; `source` | create path fields; modify path fields; delete path fields; rename old and new path fields |
| `fdr.artifact.v1` | `edited_paths`; `deleted_paths`; `renamed_paths`; `findings`; `import_provenance` | edited path action; deleted path action; renamed path action; findings.severity; `verdict` | verdict and finding-count coupling; coverage cutoff coupling; import provenance nested object required; reviewer diagnostic bounded string |
| `fdr.import-provenance.v1` | `argv`; `source_fingerprint` | `command_hash_source` | trusted import argv shape; coverage cutoff equality; source realpath identity |
| `fdr.cycle.v1` | sequence lists; log digests | `artifact_state`; `artifact_verdict`; `decision`; `challenge_reason` | challenge decision fields; allow decision sentinels; blocked decision sentinels; bypassed decision references |
| `judge.response.v1` | `findings` | `verdict`; `reason`; findings.severity; findings.source; `backend` | challenge findings required; allow and invalid findings empty; confidence decimal bounds |
| `judge.nested-token.v1` | none | none | allowed child pid unavailable sentinel; token TTL bound; parent process identity |
| `worker.context-pack.v1` | `allowed_paths`; `source_fragments`; `constraints` | `provider`; `task_kind`; `expected_output_kind`; `model_route_intent` | bounded source fragments; scope path allowlist; token budget bound |
| `worker.invocation.v1` | `hash bindings`; `model route` | `provider`; `worker_backend`; `task_kind`; `allowed_output_kind`; `decision`; `reason` | fresh scope binding; worker cannot authorize; provider-bound model route |
| `worker.result.v1` | `patch`; `findings` | `provider`; `task_kind`; `output_kind`; findings.severity; `backend` | patch output scoped; findings output scoped; clean result non-authoritative; confidence decimal bounds |
| `install.manifest.v1` | `managed_hook_entries`; `managed_hook_entries.provider_env`; `managed_hook_entries.removal_selector`; `runtime_file_records`; `runtime_config_records`; `provider_config_records`; `protected_config_records`; `fixture_manifest_records`; `selected_output_contracts` | provider; hook event; file record kind; fixture contract kind | enforcing hook entry output contract required; discovery entry output contract empty allowed; lexical active strict-hook command binding |
| `install.baseline.v1` | `managed_hook_entries`; `generated_hook_commands`; `generated_hook_env`; `runtime_file_records`; `runtime_config_records`; `provider_config_records`; `protected_config_records`; `fixture_manifest_records`; `selected_output_contracts`; `protected_file_inode_index` | `kind`; provider; file record kind; protected inode kind | protected baseline-only fields required; manifest-only fields forbidden |
| `install.transaction-marker.v1` | none | `phase` | pending marker unsettled phase; complete marker complete phase; completed pending cleanup; install staged fields; uninstall staged fields |
| `install.backup-manifest.v1` | `previous_active_runtime_fingerprint`; `provider_config_records`; `protected_config_records`; `runtime_config_records`; `backup_file_records` | `previous_active_runtime_kind`; backup file kind; `existed` | missing active runtime fingerprint; symlink active runtime fingerprint; directory active runtime fingerprint; missing backup record fields |

### 17.2.2.1 Schema Field Profile Details

Every field profile named in 17.2.2 must have exactly one row here. `field_details` stores each profile as a shape string plus member and rule arrays. These are bootstrap parser-fixture hints, not a replacement for the owner sub-spec field grammar.

| Schema id | Field profile | Shape | Members | Rules |
|---|---|---|---|---|
| `metadata.schema-profile.v1` | `hash_fields` | `array` | hash field names | top-level owner fields only |
| `metadata.schema-profile.v1` | `required_fields` | `array` | required top-level fields | comes from 17.2.1 |
| `metadata.schema-profile.v1` | `referenced_terms` | `array` | non-field code terms | excludes required_fields |
| `metadata.schema-profile.v1` | `referenced_details` | `object-map` | kind; source; rules | keys match referenced_terms |
| `metadata.schema-profile.v1` | `field_profiles` | `array` | field profile names | keys match field_details |
| `metadata.schema-profile.v1` | `field_details` | `object-map` | shape; members; rules | keys match field_profiles |
| `metadata.schema-profile.v1` | `enum_families` | `array` | enum family names | keys match enum_values |
| `metadata.schema-profile.v1` | `enum_values` | `object-map` | enum family; allowed values | keys match enum_families |
| `metadata.schema-profile.v1` | `variant_requirements` | `array` | variant rule names | keys match variant_rules |
| `metadata.schema-profile.v1` | `variant_rules` | `object-map` | selectors; requires; forbids | keys match variant_requirements |
| `metadata.schema-profile.v1` | `variants` | `array` | implementation profile clauses | non-empty prose fragments |
| `metadata.schema-profile.v1` | `variant_details` | `object-map` | index; kind; source; rules | keys match variants |
| `metadata.schema-profile.v1` | `nested_profiles` | `array` | schema profile ids | matrix ids forbidden |
| `metadata.schema-profile.v1` | `fixture_requirements` | `array` | required artifact names | binds registry artifact |
| `metadata.matrix-profile.v1` | `dimensions` | `array` | matrix dimensions | comes from 17.4.1 |
| `metadata.matrix-profile.v1` | `allowed_rows` | `array` | allowed row classes | comes from 17.4.1 |
| `metadata.matrix-profile.v1` | `forbidden_row_classes` | `array` | invalid row classes | comes from 17.4.1 |
| `metadata.matrix-profile.v1` | `fixture_requirements` | `array` | matrix proof names | binds matrix registry purpose |
| `event.normalized.v1` | `turn` | `object` | turn_id; parent turn marker; cwd/project tuple | current turn identity preserved |
| `event.normalized.v1` | `tool` | `object` | kind; name; write_intent; file_changes | absent tool uses unknown sentinels |
| `event.normalized.v1` | `tool.file_changes` | `array` | action; source; path; old_path; new_path | action-specific path shape |
| `event.normalized.v1` | `permission` | `object` | operation; access_mode; requested_tool_kind; can_approve | permission-request mirror fields |
| `event.normalized.v1` | `permission.filesystem` | `object` | access_mode; path; recursive; scope | normalized absolute path domain |
| `event.normalized.v1` | `permission.network` | `object` | scheme; host; port; operation | canonical host and port domain |
| `event.normalized.v1` | `prompt` | `object` | prompt text hash; prompt byte counts | raw prompt privacy bounds |
| `event.normalized.v1` | `assistant` | `object` | current turn text; byte count; truncated flag | truncation flag coupled to byte cap |
| `event.normalized.v1` | `raw` | `object` | raw event type; raw payload hash | raw capture bounded by config |
| `decision.internal.v1` | `metadata` | `object` | provider tuple; evidence hashes | unsafe metadata rejected |
| `decision.provider-output.v1` | `stdout_required_fields` | `array` | stdout JSON field names | sorted unique fields |
| `decision.provider-output.v1` | `stderr_required_fields` | `array` | stderr JSON field names | sorted unique fields |
| `hook.preflight.v1` | `data hash fields` | `hash-group` | reason_hash; tool_name_hash; command_hash; path_list_hash; error_hash; preflight_hash | lowercase SHA-256; preflight_hash recomputed; raw values not retained |
| `hook.preflight.v1` | `tool summary fields` | `object-fields` | tool_kind; tool_write_intent; tool_name_hash; command_hash; path_list_hash | hashed command, path list, and tool name only |
| `hook.preflight.v1` | `error diagnostic fields` | `object-fields` | error_count; error_hash | untrusted diagnostics hashed only |
| `fixture.manifest.v1` | `records` | `array` | contract_id; provider; contract_kind; fixture hashes | record hash fields match contract kind |
| `fixture.manifest.v1` | `records.fixture_file_hashes` | `object-map` | fixture relative path; sha256 | lowercase sha256 values |
| `fixture.manifest.v1` | `records.compatibility_range` | `object` | mode; exact version; min version; max version | mode-specific comparator fields |
| `config.runtime-env.v1` | `runtime config lines` | `line-list` | key; value | UTF-8 KEY=VALUE grammar |
| `config.runtime-env.v1` | `integer bounds` | `bounds-map` | key; min; max | invalid integers fall back safe |
| `config.protected-paths.v1` | `directive lines` | `line-list` | directive; target path | absolute normalized paths only |
| `config.destructive-patterns.v1` | `directive lines` | `line-list` | directive; pattern or token | no shell sourcing |
| `config.stub-allowlist.v1` | `directive lines` | `line-list` | directive; finding digest | full sha256 identity |
| `config.filesystem-read-allowlist.v1` | `directive lines` | `line-list` | directive; target path | read-only allowlisting |
| `config.network-allowlist.v1` | `network allowlist lines` | `line-list` | protocol; host; port; operation | no wildcard or tunnel entries |
| `state.ledger.v1` | `old_fingerprint` | `nested-object` | state.ledger-fingerprint.v1 | pre-mutation fingerprint |
| `state.ledger.v1` | `new_fingerprint` | `nested-object` | state.ledger-fingerprint.v1 | post-mutation fingerprint |
| `state.sequence.v1` | `last_seq_by_record_type` | `object-map` | record type; last seq | non-negative monotonic counters |
| `state.sequence.v1` | `last_record_hash_by_record_type` | `object-map` | record type; last hash | hash matches log tail |
| `state.baseline.v1` | `log_offsets` | `object-map` | log name; byte offset | offsets never exceed file size |
| `state.baseline.v1` | `last_sequences` | `object-map` | record type; last seq | matches state.sequence.v1 |
| `state.baseline.v1` | `last_safe_stop_sequences` | `object-map` | record type; safe stop seq | stop gate coverage marker |
| `state.baseline.v1` | `approval_evidence` | `array` | approval hash; audit hash; ledger hash | exact approval binding |
| `state.baseline.v1` | `project_optouts_previous` | `object-map` | opt-out path; fingerprint | previous baseline comparison |
| `state.baseline.v1` | `project_optouts_current` | `object-map` | opt-out path; fingerprint | current fingerprint activation |
| `state.baseline.v1` | `dirty path records` | `array` | path; status; fingerprint | dirty snapshot bounded |
| `state.baseline.v1` | `submodule_records` | `array` | path; commit; dirty flag | submodule state explicit |
| `state.baseline.v1` | `dirty_limits` | `object` | ignored file count; max files | overflow is fail-closed |
| `state.baseline.v1` | `protected file records` | `array` | path; fingerprint; inode tuple | protected path baseline |
| `state.baseline.v1` | `protected inode index` | `object-map` | dev+inode; protected path | symlink swap detection |
| `approval.pending.v1` | `gate_context` | `object` | gate kind; scope digest; artifact hash | quality gate evidence |
| `approval.pending.v1` | `optout_fingerprint` | `object` | path; kind; fingerprint hash | current opt-out identity |
| `approval.audit.v1` | `consumed marker fingerprints` | `object` | marker_hash; tombstone_hash; ledger_hash | consumed evidence immutable |
| `approval.audit.v1` | `resolved quality scope fields` | `object` | scope digest; artifact hash; finding count | resolved FDR challenge binding |
| `approval.audit.v1` | `opt-out fingerprint fields` | `object` | optout_kind; path; fingerprint | opt-out approval identity |
| `tool.intent.v1` | `normalized_path_list` | `array` | normalized paths | canonical absolute or unknown sentinel |
| `tool.permission-decision.v1` | `normalized_path_list` | `array` | normalized paths | allow records require concrete paths |
| `tool.permission-decision.v1` | `network_tuple_list` | `array` | network tuple entries | allow records require concrete network tuple |
| `tool.permission-decision.v1` | `network_tuple_list entries` | `object` | scheme; host; port; operation | port 1..65535 |
| `fdr.artifact.v1` | `edited_paths` | `array` | path; action; fingerprint | edit action create or modify |
| `fdr.artifact.v1` | `deleted_paths` | `array` | path; action; old fingerprint | delete action only |
| `fdr.artifact.v1` | `renamed_paths` | `array` | old_path; new_path; action | rename action only |
| `fdr.artifact.v1` | `findings` | `array` | severity; source; message; evidence | verdict coupling |
| `fdr.artifact.v1` | `import_provenance` | `nested-object` | fdr.import-provenance.v1 | required for imported artifacts |
| `fdr.import-provenance.v1` | `argv` | `array` | strict-fdr path; import; separator; source path | trusted import argv shape |
| `fdr.import-provenance.v1` | `source_fingerprint` | `nested-object` | state.ledger-fingerprint.v1 | source identity proof |
| `fdr.cycle.v1` | `sequence lists` | `array-group` | tool intent seqs; tool seqs; edit seqs | coverage cutoff bounded |
| `fdr.cycle.v1` | `log digests` | `array-group` | tool intent digest; tool digest; edit digest | digest binds sequence lists |
| `judge.response.v1` | `findings` | `array` | severity; source; message | challenge verdict requires findings |
| `worker.context-pack.v1` | `allowed_paths` | `array` | project-relative normalized paths | exact scope allowlist |
| `worker.context-pack.v1` | `source_fragments` | `array` | path; range; content_hash; text_or_omitted | bounded source excerpts only |
| `worker.context-pack.v1` | `constraints` | `array` | source path; source hash; bounded text | AGENTS/spec/FDR constraints only |
| `worker.invocation.v1` | `hash bindings` | `hash-group` | context_pack_hash; prompt_hash; input_hash; selected_source_paths_hash; output_hash; result_hash; record_hash | lowercase SHA-256; stale scope rejected |
| `worker.invocation.v1` | `model route` | `object-fields` | provider; worker_backend; worker_model; task_kind | provider-bound fixture-proven route |
| `worker.result.v1` | `patch` | `object-or-empty` | touched paths; unified diff or replacement text | scoped advisory patch only |
| `worker.result.v1` | `findings` | `array` | severity; path; line; harm; fix | file-local advisory findings |
| `install.manifest.v1` | `managed_hook_entries` | `array` | provider; provider version; config path; hook event; logical event; command; env; timeout; output contract | lexical active strict-hook command binding; duplicate selector and unsorted entries rejected |
| `install.manifest.v1` | `managed_hook_entries.provider_env` | `object-map` | env key; env value | generated protected env only |
| `install.manifest.v1` | `managed_hook_entries.removal_selector` | `object` | provider; config path; hook event; command identity; env hash; timeout; output contract; entry hash | hash-bound uninstall selection |
| `install.manifest.v1` | `runtime_file_records` | `array` | path; kind; fingerprint | runtime payload manifest |
| `install.manifest.v1` | `runtime_config_records` | `array` | path; kind; fingerprint | runtime config manifest |
| `install.manifest.v1` | `provider_config_records` | `array` | provider; path; fingerprint | provider config manifest |
| `install.manifest.v1` | `protected_config_records` | `array` | path; fingerprint; inode tuple | protected config manifest |
| `install.manifest.v1` | `fixture_manifest_records` | `array` | contract id; fixture hash | fixture proof manifest |
| `install.manifest.v1` | `selected_output_contracts` | `array` | provider; event; contract id; provider action; decision hash; fixture hashes | selected event-specific output proof |
| `install.baseline.v1` | `managed_hook_entries` | `array` | provider; hook event; command; env | lexical active strict-hook command binding; active hook baseline |
| `install.baseline.v1` | `generated_hook_commands` | `array` | provider; hook event; command argv | generated command proof; no outside install-root command |
| `install.baseline.v1` | `generated_hook_env` | `object-map` | env key; env value | protected env proof |
| `install.baseline.v1` | `runtime_file_records` | `array` | path; kind; fingerprint | active runtime baseline |
| `install.baseline.v1` | `runtime_config_records` | `array` | path; kind; fingerprint | runtime config baseline |
| `install.baseline.v1` | `provider_config_records` | `array` | provider; path; fingerprint | provider config baseline |
| `install.baseline.v1` | `protected_config_records` | `array` | path; fingerprint; inode tuple | protected config baseline |
| `install.baseline.v1` | `fixture_manifest_records` | `array` | contract id; fixture hash | fixture proof baseline |
| `install.baseline.v1` | `selected_output_contracts` | `array` | provider; event; contract id; provider action; decision hash; fixture hashes | selected event-specific output baseline |
| `install.baseline.v1` | `protected_file_inode_index` | `object-map` | dev+inode; protected path | protected file swap detection |
| `install.backup-manifest.v1` | `previous_active_runtime_fingerprint` | `nested-object` | state.ledger-fingerprint.v1 | kind-specific active runtime proof |
| `install.backup-manifest.v1` | `provider_config_records` | `array` | provider; path; backup fingerprint | provider config rollback source |
| `install.backup-manifest.v1` | `protected_config_records` | `array` | path; backup fingerprint; inode tuple | protected config rollback source |
| `install.backup-manifest.v1` | `runtime_config_records` | `array` | path; backup fingerprint | runtime config rollback source |
| `install.backup-manifest.v1` | `backup_file_records` | `array` | kind; existed; backup_relative_path; fingerprint | missing record sentinel fields |

### 17.2.3 Schema Enum Values

Every enum family named in 17.2.2 must have exactly one row here. `enum_values` stores these values as strings; numeric and empty-string sentinels are represented as `0`, `1`, and `<empty>` in metadata until the runtime parser layer adds typed enum semantics.

| Schema id | Enum family | Allowed values |
|---|---|---|
| `metadata.schema-registry.v1` | `registry_kind` | `schema` |
| `metadata.matrix-registry.v1` | `registry_kind` | `matrix` |
| `event.normalized.v1` | `provider` | `claude`, `codex`, `unknown` |
| `event.normalized.v1` | `logical_event` | `session-start`, `user-prompt-submit`, `pre-tool-use`, `post-tool-use`, `stop`, `subagent-stop`, `permission-request` |
| `event.normalized.v1` | `tool.kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `event.normalized.v1` | `tool.write_intent` | `none`, `read`, `write`, `unknown` |
| `event.normalized.v1` | `tool.file_changes.action` | `create`, `modify`, `delete`, `rename`, `unknown` |
| `event.normalized.v1` | `tool.file_changes.source` | `payload`, `patch`, `dirty-snapshot` |
| `event.normalized.v1` | `permission.operation` | `tool`, `shell`, `write`, `network`, `filesystem`, `combined`, `unknown` |
| `event.normalized.v1` | `permission.access_mode` | `read`, `write`, `execute`, `delete`, `chmod`, `network-connect`, `network-listen`, `unknown` |
| `event.normalized.v1` | `permission.requested_tool_kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `event.normalized.v1` | `permission.filesystem.access_mode` | `read`, `write`, `execute`, `delete`, `chmod`, `unknown` |
| `event.normalized.v1` | `permission.filesystem.recursive` | `true`, `false`, `unknown` |
| `event.normalized.v1` | `permission.filesystem.scope` | `file`, `directory`, `project`, `home`, `root`, `unknown` |
| `event.normalized.v1` | `permission.network.scheme` | `http`, `https`, `unknown` |
| `event.normalized.v1` | `permission.network.operation` | `connect`, `listen`, `proxy`, `tunnel`, `unknown` |
| `event.normalized.v1` | `permission.can_approve` | `true`, `false`, `unknown` |
| `event.normalized.v1` | `turn.assistant_text_truncated` | `0`, `1` |
| `decision.internal.v1` | `action` | `allow`, `block`, `warn`, `inject` |
| `decision.internal.v1` | `severity` | `info`, `warning`, `error`, `critical` |
| `decision.provider-output.v1` | `provider` | `claude`, `codex` |
| `decision.provider-output.v1` | `provider_action` | `allow`, `block`, `deny`, `warn`, `inject`, `no-op` |
| `decision.provider-output.v1` | `stdout_mode` | `empty`, `plain-text`, `json`, `provider-native-json` |
| `decision.provider-output.v1` | `stderr_mode` | `empty`, `plain-text`, `json`, `provider-native-json` |
| `hook.preflight.v1` | `logical_event` | `session-start`, `user-prompt-submit`, `pre-tool-use`, `post-tool-use`, `stop`, `subagent-stop`, `permission-request`, `unknown` |
| `hook.preflight.v1` | `decision` | `allow`, `block`, `unknown` |
| `hook.preflight.v1` | `reason_code` | `not-applicable`, `payload-untrusted`, `provider-untrusted`, `payload-truncated`, `protected-baseline-untrusted`, `preflight-error`, `shell-read-only-or-unmatched`, `non-write-tool`, `write-targets-disjoint`, `invalid-identity`, `shell-command-missing`, `shell-parse-error`, `protected-runtime-execution`, `destructive-command`, `protected-root`, `unknown-write-target`, `protected-target-unknown`, `trusted-import-invalid`, `trusted-import-unavailable` |
| `hook.preflight.v1` | `tool_kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `hook.preflight.v1` | `tool_write_intent` | `none`, `read`, `write`, `unknown` |
| `fixture.manifest.v1` | `provider` | `claude`, `codex` |
| `fixture.manifest.v1` | `contract_kind` | `payload-schema`, `matcher`, `command-execution`, `event-order`, `prompt-extraction`, `judge-invocation`, `worker-invocation`, `decision-output`, `version-comparator` |
| `fixture.manifest.v1` | `compatibility_range.mode` | `exact`, `range`, `unknown-only` |
| `config.runtime-env.v1` | `runtime key` | `STRICT_NO_ARTIFACT_GATE`, `STRICT_CAPTURE_RAW_PAYLOADS`, `STRICT_CAPTURE_FULL_TEXT`, `STRICT_LOG_VALUE_MAX_BYTES`, `STRICT_LOG_MAX_BYTES`, `STRICT_LOG_MAX_AGE_DAYS`, `STRICT_CONFIRM_MAX_AGE_SEC`, `STRICT_CONFIRM_MIN_AGE_SEC`, `STRICT_FDR_SOURCE_MAX_BYTES`, `STRICT_DIRTY_IGNORED_MAX_FILES`, `STRICT_CONFIG_LINE_MAX_BYTES`, `STRICT_CLAUDE_JUDGE_MODEL`, `STRICT_CODEX_JUDGE_MODEL`, `STRICT_JUDGE_TIMEOUT_SEC`, `STRICT_CLAUDE_WORKER_MODEL`, `STRICT_CODEX_WORKER_MODEL`, `STRICT_WORKER_TIMEOUT_SEC`, `STRICT_WORKER_CONTEXT_MAX_BYTES`, `STRICT_WORKER_RESULT_MAX_BYTES`, `STRICT_NO_HAIKU_JUDGE`, `STRICT_NO_CODEX_JUDGE`, `STRICT_NO_CLAUDE_WORKER`, `STRICT_NO_CODEX_WORKER`, `STRICT_LEGACY_CLAUDE_OPTOUTS` |
| `config.runtime-env.v1` | `boolean value` | `0`, `1` |
| `config.runtime-env.v1` | `claude judge model` | `claude-haiku-4-5-20251001` |
| `config.runtime-env.v1` | `codex judge model` | `gpt-5.3-codex-spark` |
| `config.runtime-env.v1` | `claude worker model` | `claude-haiku-4-5-20251001` |
| `config.runtime-env.v1` | `codex worker model` | `gpt-5.3-codex-spark` |
| `config.protected-paths.v1` | `directive kind` | `protect-file`, `protect-tree` |
| `config.destructive-patterns.v1` | `directive kind` | `shell-ere`, `argv-token` |
| `config.stub-allowlist.v1` | `directive kind` | `finding` |
| `config.filesystem-read-allowlist.v1` | `directive kind` | `read`, `read-tree` |
| `config.network-allowlist.v1` | `protocol` | `http`, `https` |
| `config.network-allowlist.v1` | `operation` | `connect` |
| `state.ledger.v1` | `ledger_scope` | `session`, `global` |
| `state.ledger.v1` | `writer` | `strict-hook`, `strict-judge`, `strict-worker`, `strict-fdr`, `install`, `rollback`, `uninstall`, `cleanup`, `repair` |
| `state.ledger.v1` | `target_class` | `sequence`, `prompt-sequence`, `prompt-event-log`, `tool-intent-log`, `permission-decision-log`, `tool-log`, `edit-log`, `baseline`, `ledger`, `fdr-artifact`, `fdr-cycle-log`, `nested-token`, `worker-context-pack`, `worker-invocation-log`, `worker-result-log`, `pending-approval`, `approval-marker`, `consumed-tombstone`, `approval-audit-log`, `installer-marker`, `installer-backup`, `install-manifest`, `install-release`, `active-runtime-link`, `provider-config`, `runtime-config`, `protected-config`, `protected-install-baseline` |
| `state.ledger.v1` | `operation` | `create`, `modify`, `append`, `rename`, `delete`, `checkpoint` |
| `state.ledger-fingerprint.v1` | `exists` | `0`, `1` |
| `state.ledger-fingerprint.v1` | `kind` | `missing`, `file`, `directory`, `symlink` |
| `state.checkpoint.v1` | `checkpoint_scope` | `session`, `global` |
| `state.checkpoint.v1` | `checkpointed_kind` | `prompt-event-log`, `permission-decision-log`, `ledger`, `fdr-cycle-log` |
| `state.lock-owner.v1` | `lock_scope` | `global`, `session` |
| `state.lock-owner.v1` | `transaction_kind` | `install`, `rollback`, `uninstall`, `cleanup`, `repair`, `prompt-event`, `pre-tool-intent`, `permission-decision`, `post-tool-record`, `dirty-baseline`, `protected-baseline`, `fdr-import`, `fdr-cycle`, `approval-block`, `approval-consume`, `optout-approval`, `nested-token`, `worker-context-pack`, `worker-invocation`, `worker-result` |
| `state.sequence.v1` | `record type domain` | `tool_intent`, `permission_decision`, `tool`, `edit` |
| `state.baseline.v1` | `kind` | `session-baseline`, `turn-baseline`, `dirty-baseline`, `protected-baseline` |
| `state.baseline.v1` | `dirty path status` | `tracked`, `staged`, `untracked`, `ignored`, `deleted`, `submodule` |
| `state.baseline.v1` | `project opt-out source` | `session-baseline`, `turn-baseline`, `approval-log` |
| `approval.pending.v1` | `kind` | `destructive-confirm`, `quality-bypass`, `optout-approval` |
| `approval.pending.v1` | `command_hash_source` | `shell-string` |
| `approval.pending.v1` | `optout_kind` | `disabled`, `no-static-prepass`, `no-destructive-gate`, `legacy-claude` |
| `approval.audit.v1` | `log` | `destructive`, `bypass`, `optout` |
| `approval.audit.v1` | `action` | `blocked`, `confirmed`, `consumed`, `expired`, `approved`, `resolved`, `pending` |
| `approval.audit.v1` | `source` | `pre-tool-hook`, `stop-hook`, `user-prompt-hook`, `cleanup` |
| `approval.audit.v1` | `command_hash_source` | `shell-string` |
| `approval.audit.v1` | `optout_kind` | `disabled`, `no-static-prepass`, `no-destructive-gate`, `legacy-claude` |
| `approval.marker.v1` | `kind` | `destructive-confirm`, `quality-bypass` |
| `approval.marker.v1` | `source` | `user-prompt-hook` |
| `tool.intent.v1` | `logical_event` | `session-start`, `user-prompt-submit`, `pre-tool-use`, `post-tool-use`, `stop`, `subagent-stop`, `permission-request` |
| `tool.intent.v1` | `tool_kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `tool.intent.v1` | `command_hash_source` | `none`, `shell-string`, `argv`, `trusted-import-argv` |
| `tool.intent.v1` | `write_intent` | `none`, `read`, `write`, `unknown` |
| `tool.permission-decision.v1` | `permission_operation` | `tool`, `shell`, `write`, `network`, `filesystem`, `combined`, `unknown` |
| `tool.permission-decision.v1` | `requested_tool_kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `tool.permission-decision.v1` | `decision` | `allow`, `deny` |
| `tool.permission-decision.v1` | `reason_code` | `allow-safe`, `allow-read-only`, `allow-exact-allowlist`, `deny-protected-root`, `deny-destructive`, `deny-network`, `deny-filesystem`, `deny-broad-scope`, `deny-unknown`, `deny-invalid-payload`, `deny-untrusted-state`, `deny-install-integrity`, `deny-fixture-missing`, `deny-record-failure`, `deny-policy` |
| `tool.invocation.v1` | `tool_kind` | `shell`, `write`, `edit`, `multi-edit`, `patch`, `read`, `other`, `unknown` |
| `tool.invocation.v1` | `command_hash_source` | `none`, `shell-string`, `argv`, `trusted-import-argv` |
| `tool.invocation.v1` | `write_intent` | `none`, `read`, `write`, `unknown` |
| `tool.edit.v1` | `action` | `create`, `modify`, `delete`, `rename` |
| `tool.edit.v1` | `source` | `payload`, `patch`, `dirty-snapshot` |
| `fdr.artifact.v1` | `edited path action` | `create`, `modify` |
| `fdr.artifact.v1` | `deleted path action` | `delete` |
| `fdr.artifact.v1` | `renamed path action` | `rename` |
| `fdr.artifact.v1` | `findings.severity` | `critical`, `high`, `medium`, `low`, `info` |
| `fdr.artifact.v1` | `verdict` | `clean`, `findings`, `incomplete` |
| `fdr.import-provenance.v1` | `command_hash_source` | `trusted-import-argv` |
| `fdr.cycle.v1` | `artifact_state` | `missing`, `invalid`, `clean`, `findings`, `incomplete` |
| `fdr.cycle.v1` | `artifact_verdict` | `<empty>`, `clean`, `findings`, `incomplete` |
| `fdr.cycle.v1` | `decision` | `skipped-no-turn-text`, `skipped-trivial`, `judge-unknown`, `judge-clean`, `judge-challenge`, `blocked-reused`, `bypassed` |
| `fdr.cycle.v1` | `challenge_reason` | `no-normalized-turn-text`, `trivial-diff`, `judge-clean`, `judge-reported-challenge`, `reused-blocking-challenge`, `approved-quality-bypass`, `judge-disabled`, `judge-invocation-unverified`, `judge-state-isolation-failed-until-repair`, `timeout`, `nonzero-exit`, `invalid-output`, `empty-output`, `parse-failure` |
| `judge.response.v1` | `verdict` | `clean`, `challenge`, `unknown` |
| `judge.response.v1` | `reason` | `clean`, `challenge`, `judge-disabled`, `judge-invocation-unverified`, `judge-state-isolation-failed-until-repair`, `timeout`, `nonzero-exit`, `invalid-output`, `empty-output`, `parse-failure` |
| `judge.response.v1` | `findings.severity` | `critical`, `high`, `medium`, `low`, `info` |
| `judge.response.v1` | `findings.source` | `artifact`, `assistant-text`, `scope-metadata` |
| `judge.response.v1` | `backend` | `claude`, `codex`, `unknown` |
| `worker.context-pack.v1` | `provider` | `claude`, `codex` |
| `worker.context-pack.v1` | `task_kind` | `intra-file-rewrite`, `file-review`, `stub-scan`, `fdr-sweep`, `research-summary`, `test-fix-suggestion` |
| `worker.context-pack.v1` | `expected_output_kind` | `patch`, `findings`, `rewrite-suggestion`, `review-note`, `unknown` |
| `worker.context-pack.v1` | `model_route_intent` | `provider-bound-cheap-worker`, `local-mock`, `none` |
| `worker.invocation.v1` | `provider` | `claude`, `codex` |
| `worker.invocation.v1` | `worker_backend` | `claude`, `codex`, `local-mock`, `unknown` |
| `worker.invocation.v1` | `task_kind` | `intra-file-rewrite`, `file-review`, `stub-scan`, `fdr-sweep`, `research-summary`, `test-fix-suggestion` |
| `worker.invocation.v1` | `allowed_output_kind` | `patch`, `findings`, `rewrite-suggestion`, `review-note`, `unknown` |
| `worker.invocation.v1` | `decision` | `accepted`, `rejected`, `unknown` |
| `worker.invocation.v1` | `reason` | `completed`, `timeout`, `nonzero-exit`, `invalid-output`, `scope-mismatch`, `route-unverified`, `state-isolation-failed`, `stale-context`, `hash-mismatch` |
| `worker.result.v1` | `provider` | `claude`, `codex` |
| `worker.result.v1` | `task_kind` | `intra-file-rewrite`, `file-review`, `stub-scan`, `fdr-sweep`, `research-summary`, `test-fix-suggestion` |
| `worker.result.v1` | `output_kind` | `patch`, `findings`, `rewrite-suggestion`, `review-note`, `unknown` |
| `worker.result.v1` | `findings.severity` | `critical`, `high`, `medium`, `low`, `info` |
| `worker.result.v1` | `backend` | `claude`, `codex`, `local-mock`, `unknown` |
| `install.manifest.v1` | `provider` | `claude`, `codex` |
| `install.manifest.v1` | `hook event` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `PermissionRequest` |
| `install.manifest.v1` | `file record kind` | `runtime-file`, `runtime-config`, `provider-config`, `protected-config`, `fixture-manifest`, `install-manifest` |
| `install.manifest.v1` | `fixture contract kind` | `payload-schema`, `matcher`, `command-execution`, `event-order`, `prompt-extraction`, `judge-invocation`, `worker-invocation`, `decision-output`, `version-comparator` |
| `install.baseline.v1` | `kind` | `protected-install-baseline` |
| `install.baseline.v1` | `provider` | `claude`, `codex` |
| `install.baseline.v1` | `file record kind` | `runtime-file`, `runtime-config`, `provider-config`, `protected-config`, `fixture-manifest`, `install-manifest` |
| `install.baseline.v1` | `protected inode kind` | `runtime-file`, `runtime-config`, `provider-config`, `protected-config`, `fixture-manifest`, `install-manifest` |
| `install.transaction-marker.v1` | `phase` | `pre-activation`, `activating`, `post-activation-failed`, `rollback-in-progress`, `uninstalling`, `uninstall-failed`, `complete` |
| `install.backup-manifest.v1` | `previous_active_runtime_kind` | `directory`, `symlink`, `missing` |
| `install.backup-manifest.v1` | `backup file kind` | `provider-config`, `protected-config`, `runtime-config`, `install-manifest`, `install-baseline`, `active-runtime` |
| `install.backup-manifest.v1` | `existed` | `0`, `1` |

### 17.2.4 Schema Variant Rule Details

Every variant requirement named in 17.2.2 must have exactly one row here. `variant_rules` stores rule details as selectors, required predicates, and forbidden predicates so parser fixtures can be generated without reverse-engineering prose. A cell value of `none` means the rule has no additional predicate in that category.

| Schema id | Variant rule | Selectors | Requires | Forbids |
|---|---|---|---|---|
| `metadata.schema-registry.v1` | `schema registry kind` | registry_kind=schema | registry_kind; sorted schema ids; registry_hash recomputed | registry_kind!=schema |
| `metadata.schema-profile.v1` | `filename schema_id binding` | filename=<schema-id>.schema.json | schema_id equals filename stem | schema_id!=filename stem |
| `metadata.schema-profile.v1` | `nested_profiles excludes matrix ids` | nested_profiles present | nested_profiles schema ids only | matrix id entries |
| `metadata.matrix-registry.v1` | `matrix registry kind` | registry_kind=matrix | registry_kind; sorted matrix ids; registry_hash recomputed | registry_kind!=matrix |
| `metadata.matrix-profile.v1` | `filename matrix_id binding` | filename=<matrix-id>.matrix.json | matrix_id equals filename stem | matrix_id!=filename stem |
| `event.normalized.v1` | `permission-request mirror fields` | logical_event=permission-request | permission object populated; requested_tool_kind mirrored | missing permission tuple |
| `event.normalized.v1` | `current-turn assistant text byte and truncation coupling` | logical_event=stop or subagent-stop | assistant text bytes; assistant_text_truncated flag | truncated flag without byte cap |
| `event.normalized.v1` | `unknown sentinel fail-closed fields` | provider=unknown or logical_event=unknown | raw_event captured; fail-closed sentinel fields | allow decision derived from unknown |
| `decision.internal.v1` | `allow empty text` | action=allow | reason=<empty>; additional_context=<empty> | reason non-empty; additional_context non-empty |
| `decision.internal.v1` | `warn warning text` | action=warn | reason non-empty; severity=warning | reason empty; severity=info |
| `decision.internal.v1` | `block reason text` | action=block | reason non-empty; severity=error or critical | reason empty |
| `decision.internal.v1` | `inject context text` | action=inject | additional_context non-empty | additional_context empty |
| `decision.provider-output.v1` | `JSON modes require sorted required-field arrays` | stdout_mode=json or stderr_mode=json | sorted stdout_required_fields; sorted stderr_required_fields | duplicate required fields |
| `decision.provider-output.v1` | `block or deny sets blocks_or_denies` | provider_action=block or deny | blocks_or_denies=1 | blocks_or_denies=0 |
| `decision.provider-output.v1` | `inject sets injects_context` | provider_action=inject | injects_context=1 | injects_context=0 |
| `decision.provider-output.v1` | `block/deny/inject observable signal` | provider_action=block, deny, or inject | non-empty output mode or non-zero exit code for block/deny; non-empty output mode for inject; captured bytes present unless block/deny exit code is non-zero | empty stdout/stderr modes with exit_code=0 for block/deny; empty inject output |
| `hook.preflight.v1` | `not-attempted sentinel fields` | attempted=false | trusted=false; decision=unknown; would_block=false; reason_code=not-applicable; data hashes zero; error_count=0 | trusted=true; nonzero data hash |
| `hook.preflight.v1` | `untrusted diagnostic sentinel fields` | attempted=true; trusted=false | decision=unknown; would_block=false; untrusted reason_code; positive error_count; nonzero error_hash; tool hashes zero | decision=allow or block; would_block=true; raw diagnostic text |
| `hook.preflight.v1` | `trusted classifier decision coupling` | attempted=true; trusted=true | decision allow or block; would_block equals block decision; classifier reason_code matches decision; error_hash zero | unknown decision; mismatched allow/block reason_code; diagnostic errors populated |
| `fixture.manifest.v1` | `hash sentinel fields by contract kind` | contract_kind selected | fixture_file_hashes match contract_kind | missing required hash sentinel |
| `fixture.manifest.v1` | `exact compatibility range` | compatibility_range.mode=exact | exact version fields | comparator fields |
| `fixture.manifest.v1` | `range compatibility comparator` | compatibility_range.mode=range | min_version; max_version; comparator | exact-only fields |
| `config.runtime-env.v1` | `key-specific value parser and safe fallback behavior` | runtime key selected | value parser bound to key; safe default on invalid | unknown key accepted |
| `config.protected-paths.v1` | `protect-file file target` | directive=protect-file | absolute file path | tree suffix |
| `config.protected-paths.v1` | `protect-tree tree target` | directive=protect-tree | absolute tree path; /** suffix | file-only path |
| `config.destructive-patterns.v1` | `shell-ere compile validation` | directive=shell-ere | POSIX ERE compiles | shell expansion |
| `config.destructive-patterns.v1` | `argv-token token comparison` | directive=argv-token | literal argv token | regex comparison |
| `config.stub-allowlist.v1` | `finding digest identity` | directive=finding | lowercase sha256 digest | line-number-only identity |
| `config.filesystem-read-allowlist.v1` | `read file target` | directive=read | absolute file path | write or execute access |
| `config.filesystem-read-allowlist.v1` | `read-tree tree target` | directive=read-tree | absolute tree path; /** suffix | protected root |
| `config.network-allowlist.v1` | `connect host and port tuple` | operation=connect | scheme; host; port 1..65535 | wildcard or CIDR host |
| `state.ledger.v1` | `session tuple required` | ledger_scope=session | provider; session_key; raw_session_hash; cwd; project_dir | empty session tuple |
| `state.ledger.v1` | `global tuple empty unless approval-tied` | ledger_scope=global | empty provider tuple or approval tied tuple | ordinary global tuple populated |
| `state.ledger.v1` | `checkpoint related hash zero sentinel` | operation=checkpoint | related_record_hash=64-zero | nonzero related_record_hash |
| `state.ledger-fingerprint.v1` | `missing sentinel fields` | exists=0; kind=missing | zero dev inode mode size mtime; empty hashes | content hash populated |
| `state.ledger-fingerprint.v1` | `file content hash` | exists=1; kind=file | content_sha256 | tree_hash or link_target |
| `state.ledger-fingerprint.v1` | `directory tree hash` | exists=1; kind=directory | tree_hash | content_sha256 |
| `state.ledger-fingerprint.v1` | `symlink link target hash` | exists=1; kind=symlink | link_target | content_sha256 |
| `state.checkpoint.v1` | `session tuple required` | checkpoint_scope=session | provider; session_key; raw_session_hash; cwd; project_dir | empty session tuple |
| `state.checkpoint.v1` | `global tuple empty` | checkpoint_scope=global | empty provider tuple | populated provider tuple |
| `state.checkpoint.v1` | `retained successor zero sentinel` | retained_successor_absent | retained_successor_record_hash=64-zero | missing retained_successor_record_hash |
| `state.checkpoint.v1` | `source ledger checkpoint binding` | source_ledger_record_hash present | ledger writer=repair; ledger operation=checkpoint | noncheckpoint source ledger |
| `state.lock-owner.v1` | `session lock tuple required` | lock_scope=session | provider; session_key; raw_session_hash; cwd; project_dir | empty session tuple |
| `state.lock-owner.v1` | `ordinary global lock tuple empty` | lock_scope=global | empty provider tuple | populated provider tuple |
| `state.lock-owner.v1` | `stale lock repair eligibility` | stale lock candidate | timeout_at expired; pid start mismatch checked | parser auto-repairs stale lock |
| `state.sequence.v1` | `zero sequence hash sentinel` | no prior record | last_record_hash=64-zero | missing zero sentinel |
| `state.sequence.v1` | `monotonic counter binding` | record update | last_seq increases; last_record_hash matches log tail | counter regression |
| `state.prompt-sequence.v1` | `zero prompt-event hash sentinel` | last_prompt_seq=0 | last_prompt_event_hash=64-zero | nonzero hash without events |
| `state.prompt-sequence.v1` | `prompt-event tail binding` | last_prompt_seq>0 | last_prompt_event_hash matches prompt-event tail | stale tail hash |
| `state.prompt-event.v1` | `first prompt-event previous hash zero sentinel` | prompt_seq=1 | previous_record_hash=64-zero | nonzero previous hash |
| `state.prompt-event.v1` | `prompt sequence monotonicity` | prompt_seq>1 | previous_record_hash matches prior prompt event | prompt_seq regression |
| `state.baseline.v1` | `session baseline extras` | kind=session-baseline | log_offsets; last_sequences; approval_evidence | dirty path records |
| `state.baseline.v1` | `turn baseline extras` | kind=turn-baseline | last_safe_stop_sequences; approval_evidence | protected file records |
| `state.baseline.v1` | `dirty baseline extras` | kind=dirty-baseline | dirty path records; dirty_limits | approval_evidence |
| `state.baseline.v1` | `protected baseline extras` | kind=protected-baseline | protected file records; protected inode index | project opt-out fingerprints |
| `approval.pending.v1` | `destructive-confirm extra fields` | kind=destructive-confirm | normalized_command_hash; command_hash_source=shell-string | gate_context |
| `approval.pending.v1` | `quality-bypass extra fields` | kind=quality-bypass | gate_context; next_user_prompt_marker | normalized_command_hash |
| `approval.pending.v1` | `optout-approval extra fields` | kind=optout-approval | optout_fingerprint; optout_kind | command_hash_source |
| `approval.audit.v1` | `destructive action fields` | log=destructive | destructive action field set; pending_record_hash | optout_kind |
| `approval.audit.v1` | `bypass action fields` | log=bypass | gate_context; pending_record_hash | optout_fingerprint |
| `approval.audit.v1` | `opt-out action fields` | log=optout | optout_fingerprint; optout_kind | normalized_command_hash |
| `approval.audit.v1` | `consumed extra fields` | action=consumed | consumed marker fingerprints | resolved quality scope fields |
| `approval.audit.v1` | `resolved extra fields` | action=resolved | resolved quality scope fields | consumed marker fingerprints |
| `approval.marker.v1` | `destructive marker fields` | kind=destructive-confirm | approval_prompt_seq; approval_log_record_hash | gate_context |
| `approval.marker.v1` | `quality-bypass marker fields` | kind=quality-bypass | gate_context; approval_prompt_seq | normalized_command_hash |
| `approval.marker.v1` | `consumed tombstone preserves marker bytes` | consumed tombstone | original marker bytes; marker_hash unchanged | rewritten marker payload |
| `tool.intent.v1` | `command absent zero hash` | command_hash_source=none | normalized_command_hash=64-zero | command payload hash |
| `tool.intent.v1` | `write intent classification` | tool_kind selected | write_intent from static classifier | unknown treated as read |
| `tool.intent.v1` | `payload hash input` | payload present | payload_hash canonical input | missing payload hash |
| `tool.permission-decision.v1` | `allow path entries must be absolute` | decision=allow | absolute normalized_path_list entries | unknown path sentinels |
| `tool.permission-decision.v1` | `deny may use unknown sentinel` | decision=deny | unknown sentinel allowed | allowlist source required |
| `tool.permission-decision.v1` | `first previous hash zero sentinel` | seq first | previous_record_hash=64-zero | missing previous hash |
| `tool.invocation.v1` | `pre-tool intent linkage` | pre_tool_intent_seq present | pre_tool_intent_hash matches intent | missing intent link |
| `tool.invocation.v1` | `command hash parity` | command_hash_source selected | command_hash equals intent normalized_command_hash | mismatched command_hash |
| `tool.invocation.v1` | `payload hash parity` | payload_hash present | payload_hash equals intent payload_hash | mismatched payload_hash |
| `tool.edit.v1` | `create path fields` | action=create | path; new_path=path | old_path populated |
| `tool.edit.v1` | `modify path fields` | action=modify | path | old_path or new_path populated |
| `tool.edit.v1` | `delete path fields` | action=delete | old_path=path | new_path populated |
| `tool.edit.v1` | `rename old and new path fields` | action=rename | old_path; new_path | missing old_path or new_path |
| `fdr.artifact.v1` | `verdict and finding-count coupling` | verdict selected | finding_count equals findings length | clean with nonzero finding_count |
| `fdr.artifact.v1` | `coverage cutoff coupling` | artifact generated | coverage cutoff seqs; seq lists bounded | seq beyond cutoff |
| `fdr.artifact.v1` | `import provenance nested object required` | imported artifact | import_provenance fdr.import-provenance.v1 | missing import_provenance |
| `fdr.artifact.v1` | `reviewer diagnostic bounded string` | reviewer present | bounded reviewer string | oversized reviewer diagnostic |
| `fdr.import-provenance.v1` | `trusted import argv shape` | command_hash_source=trusted-import-argv | argv strict-fdr import shape | arbitrary argv |
| `fdr.import-provenance.v1` | `coverage cutoff equality` | import_provenance present | cutoffs equal artifact cutoffs | mismatched cutoff |
| `fdr.import-provenance.v1` | `source realpath identity` | source_path present | source_realpath; source_fingerprint | source_realpath missing |
| `fdr.cycle.v1` | `challenge decision fields` | decision=judge-challenge | prompt_hash; response_hash; challenge_reason | zero prompt_hash |
| `fdr.cycle.v1` | `allow decision sentinels` | decision=judge-clean or skipped-trivial | zero bypass hashes | nonzero bypass hash |
| `fdr.cycle.v1` | `blocked decision sentinels` | decision=blocked-reused | original_challenge_record_hash | zero original_challenge_record_hash |
| `fdr.cycle.v1` | `bypassed decision references` | decision=bypassed | bypass_marker_hash; bypass_consumed_record_hash; bypass_ledger_record_hash | zero bypass hashes |
| `judge.response.v1` | `challenge findings required` | verdict=challenge | findings non-empty; reason=challenge | findings empty |
| `judge.response.v1` | `allow and invalid findings empty` | verdict=clean or unknown | findings empty | findings non-empty |
| `judge.response.v1` | `confidence decimal bounds` | confidence present | decimal 0..1 up to 3 fractional digits | out-of-range confidence |
| `judge.nested-token.v1` | `allowed child pid unavailable sentinel` | allowed_child_pid unavailable | allowed_child_pid=0 | negative allowed_child_pid |
| `judge.nested-token.v1` | `token TTL bound` | expires_at present | ttl <= 120s; ttl < judge timeout | excessive ttl |
| `judge.nested-token.v1` | `parent process identity` | parent_pid present | parent_process_start | missing parent_process_start |
| `worker.context-pack.v1` | `bounded source fragments` | source_fragments present | path; range; content_hash; configured byte cap | raw transcript; unbounded repository content |
| `worker.context-pack.v1` | `scope path allowlist` | allowed_paths present | normalized project-relative paths; scope_digest covers paths | out-of-scope path; protected-root path |
| `worker.context-pack.v1` | `token budget bound` | input_token_budget present | positive integer within protected config cap | unbounded context budget |
| `worker.invocation.v1` | `fresh scope binding` | result_hash nonzero | result context_pack_hash and scope_digest match invocation | stale result hash or stale context hash |
| `worker.invocation.v1` | `worker cannot authorize` | decision selected | advisory evidence only | allow, bypass, approval, FDR clean, or Stop authority |
| `worker.invocation.v1` | `provider-bound model route` | worker_backend selected | backend matches provider; model allowlist; worker-invocation fixture proof | cross-provider route; provider env override |
| `worker.result.v1` | `patch output scoped` | output_kind=patch or rewrite-suggestion | touched paths subset of context allowed_paths | protected-root path; out-of-scope path |
| `worker.result.v1` | `findings output scoped` | output_kind=findings | findings path in scope; valid severity; bounded harm and fix | empty path; empty harm; empty fix |
| `worker.result.v1` | `clean result non-authoritative` | advisory_only=true | no allow, bypass, approval, clean FDR, or Stop decision fields | authority claim |
| `worker.result.v1` | `confidence decimal bounds` | confidence present | decimal 0..1 up to 3 fractional digits | out-of-range confidence |
| `install.manifest.v1` | `enforcing hook entry output contract required` | hook enforcing=true | fixture_manifest_records decision-output | missing output contract |
| `install.manifest.v1` | `discovery entry output contract empty allowed` | hook enforcing=false | empty output contract allowed | required deny output |
| `install.manifest.v1` | `lexical active strict-hook command binding` | managed hook entry | `STRICT_HOOK_TIMEOUT_MS=<ms> STRICT_STATE_ROOT="<state-root>" [STRICT_ENFORCING_HOOK=1 STRICT_OUTPUT_CONTRACT_ID="<selected-output-contract-id>"] "<install-root>/active/bin/strict-hook" --provider <provider> <logical_event>`; timeout/state-root/provider/event parity; enforcing output-contract parity | release realpath; outside install root; shell wrapper; extra argv; provider drift; enforcing output-contract drift |
| `install.baseline.v1` | `protected baseline-only fields required` | kind=protected-install-baseline | protected_file_inode_index; generated_hook_commands | missing protected inode index |
| `install.baseline.v1` | `manifest-only fields forbidden` | baseline record | no removal selector; no manifest-only plan fields | manifest-only fields present |
| `install.transaction-marker.v1` | `pending marker unsettled phase` | phase!=complete | .pending.json path; staged hashes | .complete.json path |
| `install.transaction-marker.v1` | `complete marker complete phase` | phase=complete | .complete.json path; final hashes | staged unsettled fields |
| `install.transaction-marker.v1` | `completed pending cleanup` | pending+complete present or complete-only repair | filename/root binding; completed phase before repair; ledger create repair; pending-delete repair; cross-writer ledger mismatch refusal; complete-only create-writer/latest-pending-writer match; non-noop pending-delete preimage; phase-derived writer delete | mismatched root; invalid pending phase; cross-writer create/delete; duplicate create; duplicate delete; stale install writer for rollback complete; missing delete preimage |
| `install.transaction-marker.v1` | `install staged fields` | install marker | staged_runtime_path; staged_install_manifest_hash; staged_install_baseline_hash | empty staged_runtime_path |
| `install.transaction-marker.v1` | `uninstall staged fields` | uninstall marker | staged_runtime_path empty; previous hashes present | staged_runtime_path populated |
| `install.backup-manifest.v1` | `missing active runtime fingerprint` | previous_active_runtime_kind=missing | previous_active_runtime_fingerprint missing | backup active-runtime file |
| `install.backup-manifest.v1` | `symlink active runtime fingerprint` | previous_active_runtime_kind=symlink | link_target fingerprint | directory tree hash |
| `install.backup-manifest.v1` | `directory active runtime fingerprint` | previous_active_runtime_kind=directory | tree hash fingerprint | link_target |
| `install.backup-manifest.v1` | `missing backup record fields` | existed=0 | backup_relative_path empty; fingerprint missing | content hash populated |

### 17.2.5 Schema Implementation Clause Details

`variants` stores the exact implementation profile clauses split from the 17.2 profile row. Each split clause must be unique after trimming; duplicate implementation clauses are readiness failures because `variant_details` is keyed by clause text. `variant_details` must have exactly the same keys as `variants`, with one object per clause:

- `index`: one-based clause order within the schema profile row.
- `kind`: deterministic clause class from the first matching rule below.
- `source`: the literal string `17.2 Schema Implementation Profiles`.
- `rules`: a non-empty array whose first item is the implementation clause text with markdown code wrapping removed.

The classifier is intentionally small and deterministic. It is a bootstrap fixture aid, not a semantic replacement for owner sub-spec parsers. Classification order is: `exact-fields` for clauses beginning with `Exact`; `filename-binding` for filename clauses; `registry-kind` for `registry_kind` clauses; `registry-id-set` for sorted registry id clauses; `hash-recompute` for hash recomputation clauses; `matrix-binding` for closed matrix validator clauses; `domain` for enum, domain, directive, action, kind, variant, mode, and source clauses; `grammar` for grammar, syntax, parser, bounds, cap, and line clauses; `nested-shape` for nested, object, record, tuple, list, path, field, and schema-shape clauses; `fixture-proof` for fixture, proof, contract, install baseline, and generated command clauses; `negative-rule` for no-extra, rejection, refusal, forbidden, and fail-closed clauses; `behavior` otherwise.

Each schema profile must produce generated or hand-written parser test names that include the schema id and cover every owner-defined variant, directive kind, action shape, enum family, and nested record family. Shared nested schemas can be reused, but a parent parser test must still prove that the parent accepts each valid nested variant and rejects a malformed nested record.

## 17.3 Executable Metadata Layout

Implementation metadata must be directly enumerable, not hidden inside parser code:

```
schemas/
  schema-registry.json
  <schema-id>.schema.json
matrices/
  matrix-registry.json
  <matrix-id>.matrix.json
tools/
  generate-metadata.rb
  validate-metadata.rb
  check-metadata-generated.rb
  test-metadata-validator.rb
  test-metadata-generator.rb
```

`schema-registry.json` must parse as `metadata.schema-registry.v1` and enumerate exactly the schema ids in [Schema Registry](#171-schema-registry), including the metadata schemas themselves. `matrix-registry.json` must parse as `metadata.matrix-registry.v1` and enumerate exactly the matrix ids in [Closed Matrix Registry](#174-closed-matrix-registry). Extra ids, missing ids, duplicate ids, unknown owner links, invalid registry hashes, or metadata files whose internal id does not match the filename make implementation readiness fail. Parser tests must diff the markdown ids against these registry files before running per-schema or per-matrix fixtures.

`tools/generate-metadata.rb` is the deterministic bootstrap metadata generator for this documentation package. It must accept `--root PATH` and generate only `schemas/*.json` and `matrices/*.json` from `specs/17-implementation-readiness.md` under that root. Running it twice against the same spec must produce byte-identical managed metadata. Missing, non-file, or malformed spec roots, non-exact controlled section headings, malformed table rows with missing, extra, or empty cells, unwrapped table id cells, invalid schema/matrix id patterns, malformed hash-field cells, and unwritable or non-file output paths must fail without raw Ruby stacktraces or partial managed-metadata writes. Markdown table rows must not be silently omitted solely because the opening pipe is not followed by a space. Schema referenced-term details from 17.2.1.1 must be rejected unless their keys exactly match computed `referenced_terms`. Schema field-profile details from 17.2.2.1 must be rejected unless their keys exactly match the structured `field_profiles` from 17.2.2. Schema variant-rule details from 17.2.4 must be rejected unless their keys exactly match the structured `variant_requirements` from 17.2.2. Schema implementation clause details from 17.2.5 must be emitted with keys exactly matching generated unique `variants`; duplicate implementation clauses must be rejected as controlled generator failures. CLI usage errors exit `2`.

`tools/validate-metadata.rb` is the bootstrap metadata validator for the documentation package. It must parse metadata JSON with duplicate-key rejection, recompute registry/profile hashes, verify filename/id bindings, compare registry/profile/required-field-list/referenced-detail/structured-profile/field-detail/enum-value/variant-rule/matrix ids back to this markdown appendix, verify schema `required_fields` from 17.2.1 separately from non-field `referenced_terms`, verify `referenced_details` from 17.2.1.1 with keys exactly matching computed `referenced_terms`, verify `field_profiles`, `enum_families`, and `variant_requirements` from 17.2.2, verify `field_details` from 17.2.2.1 with keys exactly matching `field_profiles`, verify `enum_values` from 17.2.3 with keys exactly matching `enum_families`, verify `variant_rules` from 17.2.4 with keys exactly matching `variant_requirements`, verify `variant_details` from 17.2.5 with keys exactly matching unique `variants`, reject duplicate implementation clauses as validation failures, and verify the README provider-matrix header, exact ordered capability rows, unique capability rows, and status/proof cells against the closed mappings in 17.4.2. It must also accept `--root PATH` so tests can validate copied metadata, README mappings, and spec fixtures without mutating the working tree. Missing, non-file, or malformed spec roots are validation failures. Successful validation exits `0`, validation failures exit `1`, and CLI usage errors exit `2`. It is not a runtime hook and does not replace the future shared-core parsers; it is the executable drift check that prevents metadata from falling behind the spec.

`tools/check-metadata-generated.rb` must generate metadata into an isolated temporary root from the checked root's `specs/17-implementation-readiness.md` and byte-compare the result with the checked root's committed `schemas/*.json` and `matrices/*.json`. Missing, extra, manually edited, non-file, or unreadable managed metadata paths make the check fail without raw Ruby stacktraces. CLI usage errors exit `2`.

`tools/test-metadata-validator.rb` must exercise the bootstrap validator against isolated temporary roots. Its negative fixtures must prove rejection for CLI option errors, missing or malformed spec roots including non-exact controlled section headings, malformed table rows with missing, extra, or empty cells, unwrapped table id cells, invalid schema/matrix id patterns, malformed hash-field cells, malformed required-field cells, malformed referenced-detail cells, malformed structured-profile cells, malformed field-detail cells, malformed enum-value cells, and malformed variant-rule cells, unreadable metadata paths, duplicate JSON keys, non-object registries/profiles including scalar JSON values, unsupported JSON primitive types during hash recomputation, invalid registry id types, missing registry ids, missing/extra profile files, missing/extra/duplicate schema registry rows, missing/extra/duplicate schema implementation profile rows, duplicate schema implementation profile clauses, missing/extra/duplicate schema required-field rows, missing/extra/duplicate schema referenced-detail rows, missing/extra/duplicate schema structured-profile rows, missing/extra/duplicate schema field-detail rows, missing/extra/duplicate schema enum-value rows, missing/extra/duplicate schema variant-rule rows, missing/extra/duplicate matrix registry rows, missing/extra/duplicate matrix expansion rows, schema profile `required_fields` drift from the markdown required-field list, schema profile `referenced_terms` drift from the markdown implementation profile, schema profile `referenced_details` drift from 17.2.1.1, schema profile structured metadata drift from 17.2.2, schema profile `field_details` drift from 17.2.2.1, schema profile `enum_values` drift from 17.2.3, schema profile `variant_rules` drift from 17.2.4, schema profile `variant_details` drift from 17.2.5, matrix allowed-row and forbidden-row drift from the markdown expansion requirements, extra metadata fields, filename/id mismatch, stale `generated_from_spec_hash`, profile-hash mismatch, unsorted registry ids, and matrix expansion drift. No negative validator fixture may pass with a raw Ruby stacktrace in validator output.

`tools/test-metadata-generator.rb` must exercise the generator and generated-metadata checker against isolated temporary roots. Its positive fixtures must prove schema `required_fields` exclude non-field binding terms while `referenced_terms` retains those references, `referenced_details` contains exact kind/source/rule objects whose keys match `referenced_terms`, structured metadata for nested field profiles, enum families, and variant requirements is emitted without markdown code wrapping, `field_details` contains exact shape/member/rule objects whose keys match `field_profiles`, `enum_values` contains exact value sets whose keys match `enum_families`, `variant_rules` contains exact selector/require/forbid objects whose keys match `variant_requirements`, and `variant_details` contains exact index/kind/source/rule objects whose keys match unique `variants`. Its negative fixtures must prove controlled generator and checker failure for CLI usage errors, missing, non-file, or malformed spec roots, generator rejection for registry/profile/required-field-list/referenced-detail/structured-profile/field-detail/enum-value/variant-rule/implementation-clause/expansion parity failures and unwritable or non-file output paths without partial managed-metadata writes, plus checker rejection for manually edited generated metadata content, extra managed metadata files, and non-file managed metadata paths.

The four `metadata.*` schemas are bootstrap contracts. Their parsers must be fixed shared-core code, not generated from `schemas/*.schema.json`, `matrices/*.matrix.json`, or any other untrusted metadata they are validating. The bootstrap parsers must validate registry/profile metadata and hash bindings before generated or metadata-driven parsers, validators, fixture binders, or readiness gates can trust any executable metadata.

Every `<schema-id>.schema.json` file must parse as `metadata.schema-profile.v1`, and every `<matrix-id>.matrix.json` file must parse as `metadata.matrix-profile.v1`, before its contents can be used as parser or validator metadata. Installer baselines must cover it, and provider tools must not modify it. A runtime parser or validator may be generated from this metadata or hand-written against it, but enforcing activation must prove the metadata exists, parses under the metadata schemas, and matches the protected install baseline.

## 17.4 Closed Matrix Registry

These prose matrices must become explicit table-driven validators, not hand-coded scattered `if` statements:

| Matrix id | Owner | Purpose | Required validator behavior |
|---|---|---|---|
| `matrix.ledger-scope-writer-target-operation.v1` | [State Layout](07-state-layout.md) | Prevent valid enum fields from forming impossible trusted-state mutations | Reject any ledger record outside the closed scope/writer/target/operation matrix before attribution |
| `matrix.approval-log-action-source.v1` | [State Layout](07-state-layout.md) | Prevent forged approval, consume, expire, and cleanup audit records | Reject invalid log/action/source/prompt_seq combinations before marker creation or consumption |
| `matrix.fdr-cycle-decision-reason.v1` | [FDR Challenge](08-shared-core/06-fdr-challenge.md) | Bind `decision`, `challenge_reason`, prompt/response sentinels, original challenge hash, and bypass hashes | Reject mismatched decision/reason/hash sentinel combinations |
| `matrix.permission-decision-domain.v1` | [Record Edit](08-shared-core/03-record-edit.md), [Hook Event Matrix](03-hook-event-matrix.md) | Bind allow/deny to path/network unknown sentinels and approval-capable PermissionRequest behavior | Reject allow records with unknown path/network values or invalid port/path domains |
| `matrix.project-optout-effect.v1` | [7-Level Design](01-7-level-design.md) | Keep project opt-outs scoped to documented gates | Reject any opt-out effect outside the explicit may-disable/must-never-disable table |
| `matrix.runtime-config-domain.v1` | [State Layout](07-state-layout.md) | Keep runtime settings bounded and protected | Reject unknown keys, invalid bool/int/model values, unsafe logging expansion, and provider-env overrides |
| `matrix.provider-feature-gate.v1` | [Hook Event Matrix](03-hook-event-matrix.md), [README](../README.md) | Keep README/provider matrix, installer hooks, and fixture proofs aligned | Refuse enforcement when README/installer/fixtures disagree on enabled provider capability |

Each matrix must have positive tests for every allowed row class and negative tests for every forbidden row class. Negative tests must include valid individual enum values arranged in an invalid combination.

### 17.4.1 Matrix Expansion Requirements

| Matrix id | Dimensions that must be encoded as data | Allowed row classes | Mandatory invalid combinations |
|---|---|---|---|
| `matrix.ledger-scope-writer-target-operation.v1` | `ledger_scope` (`session`, `global`), writer enum, target class enum, operation enum, tuple-presence rule, and related-record hash requirements. `strict-hook` writes session sequence/log/baseline/FDR-cycle/pending/marker/tombstone plus global approval-audit records; `strict-fdr` writes only import edit/sequence state plus FDR artifacts; `strict-judge` writes only nested tokens; `strict-worker` writes only session worker context-pack, invocation, and result records; `install`, `rollback`, and `uninstall` write only global install target classes; `cleanup` may append `expired` approval-audit-log records for expired approval state, expire pending/marker state, and delete expired nested-token state without approval audit records; `repair` may write checkpoint records and matching `operation="checkpoint"` ledger records only for `prompt-event-log`, `permission-decision-log`, `ledger`, and `fdr-cycle-log`, plus clean verified stale pre-activation state only. | Session-scoped target class with session scope, full provider/session/cwd/project tuple, and an allowed session writer/operation; strict-worker append of worker-context-pack, worker-invocation-log, or worker-result-log with full provider/session/cwd/project tuple and advisory-only related record binding; global install target class with global scope, empty tuple, and `install`, `rollback`, or `uninstall` writer; global approval-audit-log append tied to the exact approval record session tuple by strict-hook or by cleanup for expired approval records; checkpoint operation on a checkpointable target class with matching `state.checkpoint.v1`, correct session/global tuple presence, 64-zero `related_record_hash`, and compaction old/new fingerprints; cleanup expiry of pending approval or approval marker state with expired approval audit plus session ledger delete; cleanup expiry of nested-token state with token TTL plus session ledger delete and no approval audit; repair checkpoint or verified stale pre-activation installer cleanup. | Session target with global scope; global install target with session scope; provider tuple missing on session records; ordinary global tuple populated without a tied approval; global checkpoint with populated provider/session/cwd/project tuple; worker target with non-strict-worker writer; strict-worker writing approval, install, tool/edit, FDR, judge, or protected config state; worker target with global scope; nested-token expiry requiring approval-audit-log evidence; `repair` creating approval evidence; `cleanup` modifying install state; `strict-fdr` writing approval or install state; `strict-judge` writing anything except nested-token records; `checkpoint` without matching `state.checkpoint.v1`; checkpoint with nonzero `related_record_hash`; checkpoint on non-checkpointable target class, including `baseline`, `approval-audit-log`, `consumed-tombstone`, `fdr-artifact`, `worker-context-pack`, `worker-invocation-log`, or `worker-result-log`; append-only logs using non-`append` outside checkpoint compaction; consumed tombstone using non-`rename`; active-runtime-link outside lexical `<install-root>/active`. |
| `matrix.approval-log-action-source.v1` | Log (`destructive`, `bypass`, `optout`), action, source, `prompt_seq`, required extra-field set, pending/marker relation, and ledger relation. Destructive pairs: `blocked/pre-tool-hook`, `confirmed/user-prompt-hook`, `consumed/pre-tool-hook`, `expired/user-prompt-hook|cleanup`. Bypass pairs: `blocked/stop-hook`, `approved/user-prompt-hook`, `consumed/stop-hook`, `resolved/stop-hook`, `expired/user-prompt-hook|cleanup`. Opt-out pairs: `pending/user-prompt-hook|stop-hook`, `approved/user-prompt-hook`, `expired/user-prompt-hook|cleanup`. | Destructive blocked by pre-tool-hook; destructive confirmed by user-prompt-hook; destructive consumed by pre-tool-hook with tombstone evidence; destructive expired by user-prompt-hook or cleanup; bypass blocked, consumed, or resolved by stop-hook; bypass approved by user-prompt-hook; bypass expired by user-prompt-hook or cleanup; opt-out pending by user-prompt-hook or stop-hook; opt-out approved by user-prompt-hook; opt-out expired by user-prompt-hook or cleanup. | Approval from `cleanup`; consume from `user-prompt-hook`; nonzero `prompt_seq` outside `user-prompt-hook`; missing consumed tombstone fields on `consumed`; resolved fields on non-`resolved`; approval without exact pending record hash and next prompt marker; expired delete without matching ledger mutation. |
| `matrix.fdr-cycle-decision-reason.v1` | Decision, allowed `challenge_reason`, judge invocation state, `cycle_index`, `max_cycles`, prompt hash sentinel, response hash sentinel, original challenge hash sentinel, bypass hash sentinels, artifact state/value coupling. | Skipped decision with zero prompt/response/original/bypass hashes; judge-clean with clean reason, nonzero prompt/response hashes, and zero bypass hashes; judge-challenge with challenge reason and nonzero prompt/response hashes; judge-unknown with unknown reason and audited unknown result; blocked-reused bound to original challenge hash; bypassed bound to marker, audit, ledger, original challenge, and bypass hashes. | `judge-clean` with unknown reason; `judge-unknown` reason outside the unknown enum; skipped decisions with nonzero prompt/response hashes; `judge-clean` or `judge-challenge` with zero prompt hash; `blocked-reused` without original challenge hash; `bypassed` without marker/audit/ledger hashes; `judge-unknown` disabling artifact gates; transient unknown reused as clean evidence. |
| `matrix.permission-decision-domain.v1` | Permission operation, requested tool kind, decision, reason code, path tuple domain, network tuple domain, allowlist source, approval-capable event proof. Allow records require concrete normalized paths, concrete network tuple fields, and port `1..65535`; deny records may use `unknown` sentinels. | Deny record with unknown path/network sentinels and safe reason code; allow filesystem record with concrete normalized path, access mode, scope, and allowlist source; allow network record with concrete scheme/host/port/operation and allowlist source; fixture-proven informational PermissionRequest with `can_approve=false`; approval-capable PermissionRequest only when deny/block contract is fixture-proven. | Allow with `unknown` path/network field; allow with port `0` or out of range; risky approval-capable event without verified deny contract; missing requested tool kind treated as read-only; invalid allowlist line creating allow; filesystem read allowlist exposing protected `dev+inode`. |
| `matrix.project-optout-effect.v1` | Opt-out kind/path and exact gates it may disable. `<project>/.strict-mode/disabled` may disable project quality gates: prompt reminder, static prepass, stop-time stub scan, missing FDR artifact gate, and FDR challenge. `no-static-prepass` may disable post-tool static prepass warnings only. `no-destructive-gate` may disable only project-destructive pattern checks outside protected-root/provider-hook/runtime-config-state/permission/broad filesystem-network gates. Legacy Claude opt-outs are disabled unless the protected runtime config enables compatibility and then map through the same rules. | Approved `disabled` opt-out disables only project quality gates; approved `no-static-prepass` disables only post-tool static prepass warnings; approved `no-destructive-gate` disables only project-destructive pattern checks outside protected-root/provider/runtime/permission/broad gates; enabled legacy Claude opt-out maps through the same approved effect table. | Any opt-out disabling protected-root integrity, provider hook config protection, runtime/config/state integrity, approval anti-forgery, audit logging, dirty-snapshot safety, broad filesystem/network denial, or permission-request gates; current-turn-created opt-out activating without exact approval; changed fingerprint reusing old approval. |
| `matrix.runtime-config-domain.v1` | Whitelisted keys, value type, integer bounds, model allowlist, resolution source, and weakening behavior. v0 keys are `STRICT_NO_ARTIFACT_GATE`, `STRICT_CAPTURE_RAW_PAYLOADS`, `STRICT_CAPTURE_FULL_TEXT`, `STRICT_LOG_VALUE_MAX_BYTES`, `STRICT_LOG_MAX_BYTES`, `STRICT_LOG_MAX_AGE_DAYS`, `STRICT_CONFIRM_MAX_AGE_SEC`, `STRICT_CONFIRM_MIN_AGE_SEC`, `STRICT_FDR_SOURCE_MAX_BYTES`, `STRICT_DIRTY_IGNORED_MAX_FILES`, `STRICT_CONFIG_LINE_MAX_BYTES`, `STRICT_CLAUDE_JUDGE_MODEL`, `STRICT_CODEX_JUDGE_MODEL`, `STRICT_JUDGE_TIMEOUT_SEC`, `STRICT_CLAUDE_WORKER_MODEL`, `STRICT_CODEX_WORKER_MODEL`, `STRICT_WORKER_TIMEOUT_SEC`, `STRICT_WORKER_CONTEXT_MAX_BYTES`, `STRICT_WORKER_RESULT_MAX_BYTES`, `STRICT_NO_HAIKU_JUDGE`, `STRICT_NO_CODEX_JUDGE`, `STRICT_NO_CLAUDE_WORKER`, `STRICT_NO_CODEX_WORKER`, and `STRICT_LEGACY_CLAUDE_OPTOUTS`. | Known boolean key with exact `0` or `1` value and non-weakening behavior; known integer key within documented bounds; known model key within the provider judge or provider worker allowlist; protected runtime.env value matching generated protected hook config; invalid non-weakening diagnostic setting falling back to safe default with config error. | Unknown key accepted silently; duplicate key using first/last parser behavior; provider env weakening protected settings; invalid integer falling back open; `STRICT_CONFIRM_MIN_AGE_SEC` greater than max age; both semantic judges disabled by generated config; any provider worker enabled without worker-invocation fixture proof; enforcing Phase 5 accepting `STRICT_NO_ARTIFACT_GATE=1`. |
| `matrix.provider-feature-gate.v1` | Provider, logical event/capability, exact README status/proof cell text, normalized README status/proof enums, selected fixture contract ids, installer manifest hook entry, protected install baseline entry, output contract id, provider version/build/platform, and enforcement status. The closed status enum is `planned`, `planned-after-proof`, `fixture-required`, `provider-specific-fixture-required`, `disabled-until-proof`, `disabled-unless-equivalent`, `conditional`, `not-required-v0`, `provider-bound-route`, and `tool-family-planned`; the closed proof enum is `config-merge-baseline`, `event-order-before-tools`, `payload-matcher-command-decision-output`, `stop-payload-output`, `event-payload-decision-output`, `approval-capable-permission`, `block-deny-baseline`, `path-evidence-dirty-snapshot`, `trusted-fdr-import-artifact-schema`, `judge-invocation`, `worker-invocation`, and `bounded-current-turn-extraction`. Every exact README status/proof phrase must map to one of these values in matrix metadata. Unknown README status or proof text is invalid unless the provider-feature matrix and installer/readiness checks are updated in the same edit. | README capability/status/proof row maps to closed enums and exact capability list; planned or discovery-only provider capability does not install enforcing hook entries; enforcing provider capability has selected fixture contract ids, manifest entry, baseline entry, and output contract id; provider-bound judge route matches Claude Haiku or Codex Spark; provider-bound worker route matches Claude Haiku-class or Codex Spark-class worker models; disabled-until-proof capability remains disabled until required fixture proof exists. | README claims enforcement without fixture proof; README status/proof text not represented in the closed enum; installer writes enforcing hook without output contract id; provider version/build drift still using old fixture; Codex FDR challenge enabled before current-turn extraction proof; worker delegation enabled before worker-invocation proof; PermissionRequest registered enforcing without deny contract; hook timeout/env proof missing while feature is marked enforcing-ready. |

### 17.4.2 Provider Feature README Status And Proof Mapping

The provider-feature matrix owns exact mappings for the `Claude Code` and `Codex CLI` status cells in [README](../README.md). v0 mappings are:

- `planned`: "Planned"
- `planned-after-proof`: "Planned after fixtures"; "Planned after current-turn extraction proof"
- `fixture-required`: "Fixture required"
- `provider-specific-fixture-required`: "Claude only when fixture-proven"
- `disabled-until-proof`: "Disabled until current-turn extraction fixture proof exists"
- `disabled-unless-equivalent`: "Disabled in v0 unless Codex exposes an equivalent hook"
- `conditional`: "Conditional"
- `not-required-v0`: "Not required by v0 bundle"
- `provider-bound-route`: "Claude Haiku"; "Codex Spark"
- `tool-family-planned`: "Planned for Write/Edit/MultiEdit/shell"; "Planned for apply_patch/shell/write-like tools"

The provider-feature matrix also owns exact mappings for the `Required proof before enforcement` cells in [README](../README.md). v0 mappings are:

- `config-merge-baseline`: "Structured config merge tests plus protected install baseline"
- `event-order-before-tools`: "Event-order proof before model tool execution"
- `payload-matcher-command-decision-output`: "Payload schema, matcher, command execution, and decision-output fixtures"
- `stop-payload-output`: "Stop payload and block/continuation output contract fixtures"
- `event-payload-decision-output`: "Event name, payload, and decision-output fixtures"
- `approval-capable-permission`: "Required if fixtures show Codex can approve risky tools outside `pre-tool-use`"
- `block-deny-baseline`: "Exact provider block/deny contract and protected baseline verification"
- `path-evidence-dirty-snapshot`: "Tool path evidence or fail-closed dirty-snapshot fallback"
- `trusted-fdr-import-artifact-schema`: "Verified `strict-fdr import -- <path>` provenance and artifact schema"
- `judge-invocation`: "`judge-invocation` fixture proving prompt delivery, sandboxing, timeout, and state isolation"
- `worker-invocation`: "`worker-invocation` fixture proving prompt delivery, no-tool sandboxing, timeout, output JSON shape, and state isolation"
- `bounded-current-turn-extraction`: "Provider normalizer must prove bounded current-turn assistant-text extraction without persisting transcripts"

The provider-feature matrix also owns exact capability cells in [README](../README.md). v0 rows, in order, are:

- "Install/config merge"
- "`session-start` / `user-prompt-submit`"
- "`pre-tool-use` / `post-tool-use`"
- "`stop` guard"
- "`subagent-stop`"
- "`permission-request`"
- "Destructive/protected-root gate"
- "Edit tracking"
- "FDR artifact import"
- "Semantic judge route"
- "Bounded worker delegation"
- "FDR challenge"

README exact status, proof, or capability text outside these lists is invalid for enforcing readiness until the mapping, matrix metadata, installer tests, and acceptance criteria are updated together.

## 17.5 Parser Rules

Trusted parsers must share these implementation rules:

- Parse JSON with duplicate-key rejection before schema validation.
- Parse protected text config as UTF-8 bytes with the configured line-length cap before directive validation; reject NUL bytes, non-UTF-8 input, inline comments, shell syntax, expansion syntax, malformed directives, invalid path/hash/host/port tokens, and parser-dependent first-match/last-match behavior according to the owning config grammar.
- Preserve owner-specific protected text failure behavior: destructive/protected/stub config malformed lines make the relevant config untrusted and enforcing decisions fail closed, while network/filesystem allowlist malformed lines are rejected as allow evidence, logged as config errors, and cannot change the meaning of unrelated valid entries.
- Reject missing fields, extra fields, wrong primitive types, non-canonical hash strings, non-finite numbers, invalid bounded decimals, invalid enum values, invalid text directives, invalid provider output shapes, invalid matrix rows, and invalid sentinels.
- Verify canonical hash fields by setting only the named hash field to an empty string, unless the owning sub-spec defines a different nested hash input.
- Validate provider/session/raw-session/cwd/project tuple fields before using the record as evidence.
- Validate protected permissions, symlink behavior, and `dev+inode` identity for any file-backed evidence.
- Treat diagnostic-only records as ineligible for approval, freshness, protected-root, and allow decisions even when their schema parses.

## 17.6 Implementation Gates

No phase may be marked enforcing-ready until the following artifacts exist for every schema id and matrix id it touches:

- parser or validator entrypoint named by schema id or matrix id
- metadata file listed in `schemas/schema-registry.json` or `matrices/matrix-registry.json`
- valid fixtures for the smallest valid input plus every owner-defined record variant, protected text directive kind, and provider output action/event shape
- malformed-format fixtures for the applicable input family: duplicate JSON key, extra JSON field, invalid protected text directive with owner-specific fail-closed or ignore-with-config-error behavior, invalid provider stdout/stderr/exit-code shape, or malformed matrix metadata
- fixture for hash mismatch rejection when the schema has a hash field
- fixture for tuple mismatch rejection when the schema contains provider/session/cwd/project fields
- positive fixtures for every allowed matrix row
- negative fixtures for every forbidden matrix row class that can be assembled from individually valid enum values
- acceptance test that proves rejected trusted evidence fails closed or remains diagnostic-only according to the owner sub-spec

If an implementation temporarily lacks one of these artifacts, the owning phase or capability must remain disabled, discovery/log-only, or activation-failing according to the owner sub-spec. Provider-facing capabilities must also remain disabled or downgraded in the README provider support matrix.

---
