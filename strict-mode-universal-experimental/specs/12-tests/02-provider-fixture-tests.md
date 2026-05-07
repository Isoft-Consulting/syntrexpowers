# 12.2 Provider Fixture Tests

Part of [Test Strategy](../12-test-strategy.md).


Use checked-in JSON fixtures:

- current normalized event tests exercise duplicate-key-safe payload parsing, exact `event.normalized.v1` nested fields, provider/logical-event domains, logical-event mismatch rejection, fail-closed sentinel defaults, shell write intent as `unknown`, write/read/patch classification, permission-request field mirroring, cwd/project containment, and network port domain rejection
- current fixture manifest tests validate empty checked-in Claude/Codex manifests as non-proof state, verify generator rehashing order, exercise payload fixture import with raw payload plus paired normalized-event and provider-proof fixture artifacts, and reject exact-schema drift, manifest hash drift, fixture record hash drift, duplicate contract ids, duplicate-key payload JSON, logical-event mismatch imports, provider mismatch imports, payload-schema records missing normalized/provider-proof roles, payload-schema hash drift, provider-proof mismatch, empty fixture-file proof sets, unsafe fixture paths, unsafe import destinations, cross-provider fixture references, symlink fixture files, symlink fixture path components, symlink import sources, fixture file hash drift, invalid compatibility ranges, missing range comparator records, and contract-kind hash sentinel mismatches
- current decision-output fixture tests require exactly one contract-id-matching provider-output metadata fixture, stdout fixture, stderr fixture, and exit-code fixture for each decision-output record, reject cross-contract capture filenames, reject metadata event/logical-event/hash drift, and reject captured stdout/stderr/exit-code drift before a provider output contract can become proof
- Claude payload -> normalized event
- Codex payload -> normalized event
- fixture manifests reject missing fields, extra fields, top-level manifest hash mismatches, record hash mismatches, fixture path/hash mismatches, invalid non-applicable hash sentinels, provider version/build drift, event/contract-kind/contract-id mismatch, missing `event-order` proof for early baseline activation, missing version comparator proof, and stale compatibility ranges before enabling enforcement
- normalized events with missing security-critical provider/permission/path/command/turn-boundary fields fail closed or degrade only according to their explicit field contract
- normalized `tool.kind` and `tool.write_intent` use closed enums; missing or unproven write intent fails closed for enforcing pre-tool and approval-capable permission events
- pre-write `unknown-content` mode is accepted only when write intent and target paths are fixture-proven; it cannot be used as a synonym for unknown write intent
- `cwd` and `project_dir` identity is normalized from hook process state, cross-checked against provider payload paths, and symlink/path-alias mismatches disable trusted approvals, artifacts, and dirty-snapshot fallback
- argv logical-event mismatch against provider payload event name fails closed for enforcing events and creates no trusted state
- provider resolution without installer-generated `--provider`, including payload-only and process-environment detection, stays fixture/manual diagnostic mode and creates no trusted state
- normalized decision -> Claude output
- normalized decision -> Codex output
- missing or drifted decision-output fixture prevents enforcing activation for both Claude and Codex blocking events and prevents prompt injection for that provider/event
- Claude SubagentStop payload and decision contract, when fixture-enabled
- Codex PermissionRequest allow and deny output contract, when fixture-enabled
- Codex judge prompt separator or stdin delivery contract
- Codex judge stdin default path and protected prompt temp-file handling, including `0600` no-follow creation under a strict-mode-owned temp directory and cleanup on timeout/error paths
- Claude and Codex judge-invocation fixtures prove executable path, required flags, model selection, disabled-tool/sandbox behavior, prompt delivery, timeout behavior, provider session/history isolation, and JSON output contract before real judge execution
- Claude and Codex worker-invocation fixtures prove provider-bound cheap model command shape, prompt delivery, no-tool/sandbox behavior, timeout, output JSON shape, and provider state isolation before `strict-worker` may call a real worker backend
- provider command-execution fixtures prove hook timeout field units and outer-timeout behavior when a native provider timeout field is generated; normalized provider timeout must exceed the protected `STRICT_HOOK_TIMEOUT_MS` self-deadline by at least 1000 ms
- provider `turn_id` stability proof across `UserPromptSubmit`, tool hooks, and `Stop`
- baseline-capable `SessionStart` or `UserPromptSubmit` is proven to run before provider tool execution, with stable provider/session/cwd/project identity
- provider current-turn assistant-text extraction fixture proves bounded `turn.assistant_text`, matching `turn.assistant_text_bytes`, correct `turn.assistant_text_truncated` marker behavior, and that raw transcript/history content plus extracted assistant text are not stored in trusted state or diagnostic logs, including when protected full-text capture is enabled
