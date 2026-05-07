# 6. Decision Contract

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


### 6.1 Internal Decision

Core scripts return internal decision JSON to `strict-hook`:

```json
{
  "schema_version": 1,
  "action": "allow",
  "reason": "",
  "severity": "info",
  "additional_context": "",
  "metadata": {}
}
```

Actions:

- `allow`
- `block`
- `warn`
- `inject`

Internal decision records are exact-schema JSON with no extra fields. `schema_version` is `1`. `severity` is one of `info`, `warning`, `error`, or `critical`. `metadata` is an object reserved for structured gate facts and must not contain raw prompts, raw provider payloads, full file contents, raw transcripts, or unredacted secrets. Action-specific text rules are closed:

- `allow`: `reason=""`, `additional_context=""`, and `severity="info"`.
- `warn`: `reason` is non-empty; `severity` is `warning`.
- `block`: `reason` is non-empty; `severity` is `error` or `critical`.
- `inject`: `additional_context` is non-empty; `reason=""`; `severity="info"`.

An internal decision with missing fields, extra fields, invalid action/severity, invalid action-specific text, or unsafe metadata is malformed. For enforcing block/deny-capable events, malformed internal decisions fail closed with the fixture-verified provider block/deny timeout/error shape when available; otherwise enforcing activation for that event is invalid.

### 6.2 Provider Emission

`emit-decision.sh` maps internal decision to provider output.

Provider emission rows are templates until a `decision-output` fixture proves the stdout/stderr/exit-code contract for the installed provider version/build and event. Enforcing activation for any blocking, denying, or prompt-injection event requires the matching provider decision-output fixture; otherwise that event stays discovery/log-only, skips injection with an audit warning, or activation fails when the event is required for safety.

Each `decision-output` fixture must bind to exact provider output metadata parsed as `decision.provider-output.v1`. The metadata record has exactly these fields and no extras: `schema_version` (`1`), `contract_id`, `provider` (`"claude"` or `"codex"`), `event`, `logical_event`, `provider_action` (`"allow"`, `"block"`, `"deny"`, `"warn"`, `"inject"`, or `"no-op"`), `stdout_mode` (`"empty"`, `"plain-text"`, `"json"`, or `"provider-native-json"`), `stdout_required_fields`, `stderr_mode` (`"empty"`, `"plain-text"`, `"json"`, or `"provider-native-json"`), `stderr_required_fields`, `exit_code`, `blocks_or_denies`, `injects_context`, and `decision_contract_hash`. `event` and `logical_event` must both bind to the fixture manifest record's event before the record can be selected for that logical event. `stdout_required_fields` and `stderr_required_fields` are sorted unique arrays of provider-native field names and are empty for non-JSON modes. `exit_code` is the exact integer exit status required by the fixture. `blocks_or_denies` is `1` only for `provider_action="block"` or `"deny"`; `injects_context` is `1` only for `provider_action="inject"`; all other combinations are invalid. A `block` or `deny` provider action must have at least one observable blocking signal: a non-empty output mode or a non-zero exit code, and captured fixture bytes must contain stdout/stderr bytes unless the exit code is non-zero. An `inject` provider action must have a non-empty output mode and non-empty captured stdout/stderr bytes. `decision_contract_hash` is SHA-256 over canonical provider output metadata with only `decision_contract_hash` set to an empty string. A fixture manifest record's `decision_contract_hash` must equal this metadata hash and the captured stdout/stderr/exit-code fixtures must match the metadata before the emitter may use that contract.

Decision-output fixture files are exact contract-id siblings under `providers/<provider>/fixtures/decision-output/<event-component>/`: `<contract-id>.provider-output.json`, `<contract-id>.stdout`, `<contract-id>.stderr`, and `<contract-id>.exit-code`. Cross-contract capture files in the same event directory are not valid proof for another contract id.

Claude-compatible behavior:

- PreToolUse block: exit `2`, reason on stderr
- Stop block: stdout JSON `{"decision":"block","reason":"..."}`
- UserPromptSubmit inject: stdout additional context, exit `0`
- PostToolUse: always exit `0`; errors logged
- These Claude rows still require checked fixture proof before enforcing activation; a missing or drifted Claude decision-output fixture is treated the same as a missing Codex fixture for the affected event.

Codex-compatible behavior:

- Prefer JSON hook output when Codex event supports it.
- Stop block must use the Codex-recognized stop hook continuation format. For Codex `0.128.0`, `decision:"block"` on Stop does not hard-deny the final answer; it continues the same turn with the supplied reason as an additional prompt, and the hook must allow the follow-up Stop when `stop_hook_active=true` to avoid recursion. Fixture test required before enabling fail-closed.
- PreToolUse block must use Codex-recognized blocking format. Fixture test is required before enabling any fail-closed `pre-tool-use` enforcement for the installed Codex version.
- PermissionRequest block must use Codex-recognized permission-deny format. Fixture tests must prove both allow and deny outputs before `permission-request` can enforce anything beyond log-only discovery. If fixtures prove PermissionRequest can approve risky shell/write/patch/network/filesystem operations but a deny output contract is not verified, universal v0 must fail activation for that provider or keep the provider in discovery-only mode with risky in-agent approvals disabled by installer policy. There is no fallback allow path for approval-capable PermissionRequest.
- UserPromptSubmit injection must use a fixture-verified Codex-recognized injection/additional-context format before any Codex prompt reminder is emitted. Without that fixture, Codex `user-prompt-submit` may still run health/baseline work but must return the safest provider-compatible allow/no-op output.
- PostToolUse must always avoid breaking tool result unless Codex documents a safe warning path.

Until Codex output semantics are fixture-verified for a specific event and gate, that Codex gate stays log/warn-only. Clearly matched destructive commands can enforce only after the Codex `PreToolUse` block contract fixture proves the blocking output for that installed Codex version.

Approval flows require verified `user-prompt-submit` access to the actual user prompt. A provider without proven user prompt extraction must not fall back to file-based approvals. For that provider, destructive commands remain blocked with remediation to run the command manually outside the agent, and quality/opt-out bypass approvals are unavailable until prompt extraction is proven.

---
