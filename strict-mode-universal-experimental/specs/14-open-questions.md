# 14. Open Questions

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


1. What exact stdin JSON does Codex send for each hook event for each installed Codex version/build covered by the fixture manifest?
2. What exact stdout/stderr/exit-code contract does Codex require for `PreToolUse` block?
3. What exact stdout/stderr/exit-code contract does Codex require for `Stop` continuation/block?
4. What exact stdout/stderr/exit-code contract does Codex require for `PermissionRequest` allow/deny, if that event can approve risky operations?
5. Does Codex expose bounded current-turn assistant text to `Stop` hooks, or can fixtures prove safe extraction when only transcript/history paths are exposed without persisting raw transcript content or guessing turn boundaries?
6. Does Codex expose file paths for `apply_patch` in `PostToolUse`?
7. Does Codex `UserPromptSubmit` support additional context injection the same way Claude does?
8. Can Codex hook payloads expose a stable current user prompt before model execution for confirmation handling?

Closed v0 decisions:

- Shared state lives only in `~/.strict-mode/state`; provider-native state symlinks are out of scope for v0.
- Universal install starts fresh and does not migrate current `~/.claude/state` history.
- Approval phrases are exactly `strict-mode confirm <hash>`, `strict-mode bypass <hash>`, and `strict-mode approve-optout <hash>`; localized aliases are out of scope for v0.

---
