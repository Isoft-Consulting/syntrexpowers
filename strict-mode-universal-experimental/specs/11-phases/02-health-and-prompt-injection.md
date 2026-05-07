# Phase 2 — Health And Prompt Injection

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: safe low-risk hooks for both providers.

Deliverables:

- shared health check
- shared prompt reminder
- provider-compatible injection output

Acceptance:

- no blocking behavior yet
- bare `STRICT_MODE_NESTED=1` does not bypass hooks
- prompt injection appears in Claude and Codex only when the provider supports it and the installed version has a matching injection `decision-output` fixture; otherwise the event logs and returns allow/no-op
