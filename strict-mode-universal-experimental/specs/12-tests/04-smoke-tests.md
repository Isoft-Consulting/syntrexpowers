# 12.4 Smoke Tests

Part of [Test Strategy](../12-test-strategy.md).


Manual or semi-automated:

- Claude Stop hook writes log
- Codex Stop hook writes log
- Claude destructive command blocks
- Codex destructive command blocks
- nested judge invocation does not recurse
- bare nested env bypass attempt is logged and does not skip enforcement
- agent-created destructive opt-out file during a turn is ignored
- agent-created destructive opt-out file is not accepted on the next turn without explicit user approval
- agent-created quality bypass file during a turn is ignored
- generic user affirmations do not create confirmation, bypass, or opt-out approval files
- agent-created runtime edits, confirmation files, bypass files, audit-log writes, or project `.strict-mode/` config writes are blocked
- write/edit/patch payload with missing or non-normalizable target path evidence blocks before execution in enforcing mode
- provider shell attempt to run `strict-judge` or `strict-hook` directly is blocked
- agent-created edits to `~/.claude/settings.json`, `~/.codex/hooks.json`, or `~/.codex/config.toml` are blocked
- direct provider-tool writes to trusted state-root FDR artifacts are blocked
- protected-root tampering through indirect shell execution is detected before Stop allow
- missing protected-baseline blocks Stop after provider tool execution
- missing or inconsistent protected-install-baseline blocks trusted approvals/imports with repair guidance
- non-git project shell edit blocks Stop with clear remediation

No test may write to real `~/.claude`, `~/.codex`, or `~/.strict-mode` unless explicitly running an install smoke test with user approval.

---
