# 0. Summary

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


The current `strict-mode-bundle` is Claude Code-specific: it installs into `~/.claude`, writes `~/.claude/settings.json`, reads Claude transcript JSONL, and invokes `claude -p` for judge workflows.

This experimental version introduces a provider-aware runtime with one shared enforcement core:

```
provider hook payload
  -> strict-hook --provider <provider> entrypoint
  -> verify or detect provider
  -> normalize into StrictModeEvent JSON
  -> run shared core logic
  -> emit provider-compatible decision
```

Provider-specific behavior is allowed only in provider verification/detection, normalization, decision emission, installer config writers, and judge backend routing. Enforcement rules must live in shared core scripts.

---

