# 4. Normalized Event Contract

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


All provider payloads must normalize to this JSON shape before core logic runs.

```json
{
  "schema_version": 1,
  "provider": "claude",
  "logical_event": "pre-tool-use",
  "raw_event": "PreToolUse",
  "session_id": "string-or-empty",
  "parent_session_id": "string-or-empty",
  "turn_id": "string-or-empty",
  "cwd": "/absolute/path",
  "project_dir": "/absolute/path",
  "transcript_path": "/absolute/path-or-empty",
  "turn": {
    "assistant_text": "current turn assistant text when available",
    "assistant_text_bytes": 0,
    "assistant_text_truncated": 0,
    "edit_count": 0,
    "has_fdr_context": false
  },
  "tool": {
    "name": "Write",
    "kind": "write",
    "write_intent": "none|read|write|unknown",
    "command": "",
    "file_path": "/absolute/or/provider/path",
    "file_paths": ["/all/touched/paths/when-known"],
    "file_changes": [
      {
        "path": "/absolute/or/project/path",
        "old_path": "/absolute/or/project/path-before-rename-or-empty",
        "new_path": "/absolute/or/project/path-after-rename-or-empty",
        "action": "create|modify|delete|rename|unknown",
        "source": "payload|patch|dirty-snapshot"
      }
    ],
    "content": "new full content when available",
    "old_string": "old edit string when available",
    "new_string": "new edit string when available",
    "patch": "raw patch when available"
  },
  "permission": {
    "request_id": "provider permission request id when available",
    "operation": "tool|shell|write|network|filesystem|combined|unknown",
    "access_mode": "read|write|execute|delete|chmod|network-connect|network-listen|unknown",
    "requested_tool_kind": "shell|write|edit|multi-edit|patch|read|other|unknown",
    "requested_command": "shell command when the permission request exposes it",
    "requested_paths": ["/absolute/or/provider/path-or-unknown"],
    "filesystem": {
      "access_mode": "read|write|execute|delete|chmod|unknown",
      "paths": ["/absolute/or/provider/path-or-unknown"],
      "recursive": "true|false|unknown",
      "scope": "file|directory|project|home|root|unknown"
    },
    "network": {
      "scheme": "http|https|unknown",
      "host": "canonical-host-or-ip|unknown",
      "port": 443,
      "operation": "connect|listen|proxy|tunnel|unknown",
      "url": "url-or-empty|unknown"
    },
    "can_approve": "true|false|unknown"
  },
  "prompt": {
    "text": "user prompt when available"
  },
  "assistant": {
    "last_message": "assistant message when provider supplies it"
  },
  "raw": {}
}
```

Rules:

- `provider` must be one of `claude`, `codex`, `unknown`.
- `logical_event` must be passed by entrypoint argv. If the provider payload exposes an event name, it must match the argv logical event; mismatch is logged as `logical event mismatch`, creates no trusted state, and fails closed for enforcing events outside Phase 0/log-only fixture capture.
- `tool.kind` is the stable core category:
  - `shell`
  - `write`
  - `edit`
  - `multi-edit`
  - `patch`
  - `read`
  - `other`
  - `unknown`
- `tool.write_intent` is security-critical and must be one of `none`, `read`, `write`, or `unknown`, matching the tool-intent and tool-log domain. Built-in write/edit/multi-edit/patch categories are `write`; built-in read categories are `read`; events without a tool use `none`; shell and `other` tools must be classified from fixture-proven provider tool semantics plus parsed command/path evidence. If a pre-tool or permission payload cannot prove a tool is read-only, `write_intent="unknown"` fails closed in enforcing mode rather than relying on Stop fallback after a write may already have happened.
- `raw` is preserved only for diagnostic logs and fixture generation after redaction/truncation. Provider transcript/session-history content and normalized `turn.assistant_text` are excluded from raw diagnostic persistence even when protected full-text capture is enabled.
- Missing non-security string fields become empty strings, missing non-security arrays become `[]`, and missing non-security numbers become `0`. Missing security-critical fields must use the field's explicit unknown/fail-closed sentinel rather than a permissive default; this includes permission approval capability, permission access modes, filesystem recursive mode, network scheme/host/port, network/filesystem scope, write intent, provider identity, logical event identity, command identity, path evidence, and current-turn boundary fields. Missing booleans become `false` only for fields whose schema explicitly documents that `false` is a safe default.
- `cwd` and `project_dir` are security-critical identity fields. They must be normalized absolute paths derived from the hook process cwd and strict-mode project resolver; provider payload paths are advisory and must match after normalization and realpath checks before they can be used. `project_dir` must be the resolved project root, and `cwd` must be equal to or inside `project_dir` unless a fixture-proven provider event explicitly represents out-of-project work, in which case approvals, bypasses, opt-outs, FDR artifacts, and dirty-snapshot fallback are disabled for that event. If `cwd` or `project_dir` contains NUL/newline, cannot be resolved, traverses symlink components in a way the resolver cannot verify, or changes identity within one provider/session without a new trusted baseline, enforcing events fail closed.
- Normalized path fields are byte-exact UTF-8 strings after `.`/`..` collapse and separator normalization; strict-mode must not case-fold or Unicode-normalize paths for equality. Realpath and `dev+inode` checks are used for alias detection. Project-relative paths are accepted only when the normalized absolute path remains inside the resolved `project_dir`; otherwise the path is outside scope and cannot satisfy allowlists, artifact coverage, or approval hashes.
- Normalizer must never execute commands.
- `tool.file_changes` is authoritative when action is known. For `rename`, `old_path` and `new_path` must be populated when provider payload or patch headers expose them; `path` is the new path convenience value. `tool.file_paths` is the path-only projection of `tool.file_changes`, including both `old_path` and `new_path` for renames. `tool.file_path` is a convenience alias for the first path only.
- For `permission-request`, normalizer must populate `permission` from the provider payload and mirror any exposed command/path/tool data into `tool`, including `tool.write_intent`, where possible so the shared destructive/protected-path gates can run without provider-specific branches. `permission.requested_tool_kind` is `unknown` when the provider omits or ambiguously encodes the requested tool category; approval-capable requests with `unknown` tool kind fail closed unless fixtures prove the event is informational only. `permission.can_approve` is a tri-state string: `"true"`, `"false"`, or `"unknown"`. `"false"` is trusted only when provider fixtures prove the event is informational for the installed provider version; missing approval capability data for a possibly approval-capable event is `"unknown"`, not `"false"`. If the provider exposes network or filesystem approval details, the normalizer must populate `permission.network` or `permission.filesystem`; missing access mode, recursive mode, scheme, host, port, operation, scope, or path fields become `unknown` and fail closed under the permission policy. `permission.network.port` is either an integer `1..65535` or the exact string `"unknown"`; `0`, negative values, floats, numeric strings, and out-of-range ports are invalid and cannot satisfy an allowlist. `permission.network.url` may be empty only when exact scheme/host/port/operation fields are populated; an `unknown` URL cannot by itself satisfy a network allowlist. Missing path arrays are represented as `["unknown"]` unless fixtures prove the request has an intentionally empty target set.
- `turn_id` is trusted only after provider fixtures prove it is a per-user-prompt turn marker: stable across all hooks for the same user turn, changes before the next user turn, and is distinct from provider session/thread ids. If proof is absent or ambiguous, the normalizer must set `turn_id` to an empty string and preserve the raw provider field only in redacted diagnostics; current-turn filtering then uses the last safe turn-baseline sequence/byte-offset boundary plus unresolved blocked Stop scope carry-over.
- Current-turn extraction is a normalization responsibility. `turn.assistant_text` is the exact bounded current-turn assistant text excerpt available to FDR challenge, not raw session history. `turn.assistant_text_bytes` is the UTF-8 byte length of that exact excerpt after bounding; it is `0` only when `turn.assistant_text` is empty. `turn.assistant_text_truncated` is `0` or `1`; `1` is valid only when the fixed truncation marker is present exactly once in the bounded excerpt. Core FDR challenge logic must consume `turn.assistant_text`, `turn.assistant_text_bytes`, `turn.assistant_text_truncated`, `turn.edit_count`, and `turn.has_fdr_context`; it must not parse Claude or Codex transcripts directly.

---
