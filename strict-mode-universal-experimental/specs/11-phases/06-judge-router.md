# Phase 6 — Judge Router

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: semantic judge can run through provider-appropriate cheap model.

Deliverables:

- `strict-judge`
- Claude -> Haiku
- Codex -> Spark
- timeout and recursion guard
- protected nested token creation and validation
- exact `judge.response.v1` parser with verdict/reason coupling
- audited semantic `unknown` classification that does not disable other Stop gates

Acceptance:

- Claude judge mock and real command path tested
- Codex judge mock and command construction tested
- Claude and Codex judge invocation fixtures prove the full executable/flag/prompt/output contract before real provider invocation is enabled
- Claude and Codex judge invocation fixtures prove provider session/history isolation before real provider invocation is enabled
- judge responses with mismatched `verdict`/`reason`, malformed confidence, wrong backend/model, or invalid finding schema map to audited `judge-unknown`
- judge failure logs and does not trap stop forever
- Codex judge prompt delivery uses stdin by default; argv prompt delivery is allowed only with a fixture-verified `--` separator and unguarded positional prompt invocation is rejected
- cross-provider judge routing is rejected: Claude cannot select Codex Spark and Codex cannot select Claude Haiku through runtime config or provider tool environment
- protected judge model overrides are accepted only for allowed Haiku models on Claude and allowed Codex Spark models on Codex
- protected judge disable flags default to off; when set to `1`, they return audited `judge-disabled` unknown for only the matching active provider and do not disable artifact or Stop gates
- valid nested judge token skips recursive judge hooks
- bare `STRICT_MODE_NESTED=1` cannot bypass hooks without a valid nested judge token
