# 8.11 Bounded Worker Delegation

Part of [Shared Core Components](../08-shared-core-components.md).

Bounded worker delegation is the token-saving path for file-level development, review sweeps, and narrow rewrite suggestions. It lets the active provider ask a cheaper model to work on a compact context pack instead of sending the full project, transcript, or long instruction bundle again.

This component is an optimization and evidence source, not an authority. A worker result can propose a patch, list findings, summarize a file-local invariant, or produce a review note. It cannot allow a provider tool, approve a bypass, mark FDR clean, disable a Stop gate, update safe-turn boundaries, or create trusted state by itself. Any worker-suggested code change must still be applied through normal provider tools and then pass the ordinary tool-intent, edit, artifact, Stop, and FDR gates.

## 7-Level Slice

| Level | Contract |
|---|---|
| Supersystem | Runs inside the same Claude/Codex local hook ecosystem as the rest of strict-mode, with optional nested cheap-model invocations protected like judge calls. |
| Mission | Reduce token cost for file-level development while preserving strict-mode provenance and final-gate authority. |
| Concept | A bounded prompt runner that receives a small context pack and returns advisory output. It is not a second autonomous agent with write authority. |
| Values | Small context, explicit scope, deterministic hashing, no transcript persistence, no authority escalation, provider-bound routing. |
| Skills | Build context packs, route to provider-appropriate cheap workers, record invocation/result provenance, detect stale results, expose advisory findings to FDR. |
| Behaviors | File-local rewrite suggestion, file-local review sweep, diff-to-contract check, stub/static finding explanation, narrow test-fix suggestion. |
| Environment | Provider CLIs, protected temp prompt files, strict-mode state locks, selected file snippets, current diff metadata, schema parsers, and fixture-proven invocation contracts. |

## Context Pack

A context pack is a compact JSON object built by strict-mode-owned code before invoking a worker. It includes only the data needed for the assigned narrow task:

- provider/session/cwd/project tuple
- worker task kind
- bounded file list and normalized project-relative paths
- selected file excerpts or full single-file content when within configured byte caps
- current diff hunks or path fingerprints when relevant
- local constraints from `AGENTS.md`, nearby specs, or FDR scope metadata, each as bounded text plus source path/hash
- expected output kind: `patch`, `findings`, `rewrite-suggestion`, `review-note`, or `unknown`
- model route intent: `provider-bound-cheap-worker`, `local-mock`, or `none`
- explicit forbidden operations: no provider tool calls, no hidden file reads, no approvals, no Stop/FDR clean authority

The pack must not include raw provider transcripts, raw session history, hidden chain-of-thought, full repository dumps, secrets, `.env` contents, provider config files, strict-mode state files, approval markers, bypass markers, nested tokens, or protected runtime config. If a requested task needs prohibited data, worker delegation is skipped and the orchestrating provider must use normal local reasoning or ask for explicit user direction.

Every context pack is hash-bound as `worker.context-pack.v1`. The hash covers normalized task metadata, ordered source records, bounded content hashes, omitted-content sentinels, model routing intent, and output expectations. If the file content or diff scope changes after a context pack is built, any result from that pack is stale until a new pack is created.

## Invocation

`strict-worker` owns worker-model invocation. It may share the nested-token machinery from `strict-judge`, but worker tokens are distinct from judge tokens and cannot validate as judge tokens. Real worker invocation is enabled only after provider fixture proof shows the selected command, model flag, prompt delivery mode, sandbox/no-tool behavior, state isolation, timeout behavior, and output shape for the installed provider version/build.

Default worker route:

| Active provider | Worker backend | Default worker model |
|---|---|---|
| `claude` | `claude -p` | cheapest fixture-proven Haiku-class worker model |
| `codex` | `codex exec` | cheapest fixture-proven Spark-class worker model |
| `unknown` | none | worker skipped |

The worker route is provider-bound. Claude sessions cannot route file-level worker prompts through Codex, and Codex sessions cannot route them through Claude, unless a future explicit cross-provider fixture and user-approved policy is added. Provider tool environment and project files cannot override worker model, backend, timeout, context byte cap, result byte cap, or capture settings. Protected runtime config may disable workers per provider; default generated runtime config disables real workers until `worker-invocation` fixture proof exists for the installed provider. Until strict-mode has a proof-bound enable path, setting a provider worker disable flag to `0` is invalid rather than a silent enable. Disabling workers must not disable FDR, Stop, artifact validation, or judge challenge gates.

`worker.invocation.v1` records the provider/session tuple, task kind, route, model, context-pack hash, prompt hash, selected source paths hash, allowed output kind, timeout, and invocation state. It is append-only trusted state written under the same session lock discipline as other current-turn evidence. Invocation records are diagnostic/evidence records only; they do not advance tool/edit sequences or safe Stop boundaries.

Trusted worker state is split into three records:

- `worker.context-pack.v1`: the bounded prompt package and its source/hash scope
- `worker.invocation.v1`: the provider-bound route, model, prompt hash, selected source paths hash, timeout, output hash, result hash, decision, and hash-chain linkage
- `worker.result.v1`: the parsed advisory output, invocation/context binding, output kind, confidence, and `advisory_only=true` authority sentinel

## Result

Worker output must parse as exactly one `worker.result.v1` JSON object. Markdown, prose wrappers, multiple JSON objects, or output outside the declared result schema make the result invalid.

Allowed result kinds:

- `patch`: a suggested unified diff or provider-native patch text for the declared files only
- `findings`: file-local findings with severity, path, line, harm, and fix text
- `rewrite-suggestion`: bounded replacement text for one declared region
- `review-note`: bounded advisory note tied to declared scope
- `unknown`: worker could not complete safely

Every result binds to the invocation hash and context-pack hash, and every valid result must set `advisory_only=true`. For `patch` and `rewrite-suggestion`, strict-mode must verify that every touched path was in the context pack and outside protected roots before presenting the suggestion for application. Applying the suggestion still goes through normal provider tools and creates normal tool/edit state. For `findings` and `review-note`, strict-mode may include the result as an input to FDR artifact generation or challenge prompts, but it cannot treat absence of findings as clean evidence.

Stop may use worker records only to reject stale or forged evidence. It must not allow Stop solely because a worker result says the scope is clean. If a policy requires a worker sweep for a scope, the sweep must be fresh by content-scope fingerprint, context-pack hash, invocation hash, result hash, model route, and task kind; stale or invalid worker evidence is a quality diagnostic or configured quality block, not a bypass of other gates.

## Token Economy Rules

- Prefer one-file or one-component context packs over full-project prompts.
- Include hashes and path identities for omitted content instead of full text when possible.
- Reuse fresh worker findings by context-pack hash; do not rerun cheap workers for unchanged file fingerprints and unchanged task constraints.
- Expire worker results when any source file fingerprint, diff hunk, relevant spec/AGENTS excerpt hash, or output expectation changes.
- Never send raw transcript/history to a worker to save tokens; transcript-derived current-turn text remains governed by FDR Challenge privacy rules.

## Failure Behavior

- Missing worker fixture proof disables worker delegation for that provider.
- Timeout, nonzero exit, malformed output, output path outside scope, model/backend mismatch, state-isolation failure, stale context, or hash mismatch records `worker.result.v1` with `output_kind=unknown` or rejects the result before trusted state append.
- Worker failure must not trap a session forever. The orchestrating provider can continue with normal local reasoning, but any gate that explicitly required a fresh worker sweep remains unresolved until a fresh valid result or an approved quality bypass covers that exact gate.
- Worker prompts and results are redacted and bounded. Full file content capture is allowed only for files explicitly listed in the context pack and within byte caps; otherwise only excerpts and hashes are retained.

## Non-Authority Rules

A worker result must never:

- create or consume confirmation, bypass, or opt-out approvals
- write strict-mode state directly
- mark an FDR artifact clean
- suppress a Stop block
- change provider hook config
- alter protected runtime config
- replace judge challenge output
- authorize protected-root writes
- decide that an unknown payload is safe

These rules apply even when the worker model is the same vendor family as the active provider. The source of authority is strict-mode's protected state and gates, not model self-report.

---
