# 8.8 Prompt Injection And Health Check

Part of [Shared Core Components](../08-shared-core-components.md).


`core/prompt-inject.sh` and `core/health-check.sh` provide low-risk session guidance and diagnostics.

Rules:

- Prompt injection content is shared text from `templates/strict-rules.md`.
- Provider-specific formatting of injected context belongs in `emit-decision.sh`.
- Prompt injection is emitted only when the installed provider/event has a matching `decision-output` fixture for injection/additional-context output. If a provider does not support prompt injection or the fixture is missing/drifted, log once per session and allow with no injected text.
- An active `<project>/.strict-mode/disabled` or enabled legacy quality opt-out may suppress the prompt reminder only after the same active opt-out validation used by Stop: immutable session-baseline fingerprint or exact approved `optout-log.jsonl` evidence, current fingerprint/path/owner/permission match, and protected-root integrity verified. A current-turn or unapproved opt-out file must not suppress prompt injection. Prompt opt-out affects reminder text only; it must not suppress health checks, baseline capture, prompt sequence allocation, approval phrase parsing, protected-root integrity checks, or install-integrity warnings.
- Health check validates dependencies, install root readability, state directory permissions, and whether semantic judge is enabled or disabled.
- Health check must not block normal work in Phase 2; hard dependency failures become actionable warnings until the corresponding enforcing phase is enabled.
