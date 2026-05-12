# 9. Judge Router

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


`bin/strict-judge` owns all semantic judge calls.

Judge routing is separate from bounded worker delegation. `strict-judge` is allowed to produce FDR challenge verdicts under `judge.response.v1`; `strict-worker` is allowed only to produce advisory file-level worker results under `worker.result.v1`. A worker route must not be reused as a judge route, and a judge route must not be used for cheap file-level development unless the worker fixture contract is separately proven.

Default routing:

| Provider | Backend command | Default model |
|---|---|---|
| `claude` | `claude -p` | `claude-haiku-4-5-20251001` |
| `codex` | `codex exec` | `gpt-5.3-codex-spark` |
| `unknown` | none | semantic judge unknown; other Stop gates still apply |

The command rows are templates, not ambient trust. `strict-judge` may invoke a provider only when a checked-in `judge-invocation` fixture for the installed provider version/build proves the executable path, required flags, prompt delivery mode, model selection flag, timeout behavior, disabled-tool/sandbox behavior, provider session/history isolation, and expected exit/output contract. If any required flag, prompt-delivery, or state-isolation contract is unproven for the installed provider, `strict-judge` returns `verdict:"unknown"` with `reason:"judge-invocation-unverified"` rather than trying a nearby command shape.

The provider invocation gate does not forbid deterministic local classification. When `strict-judge` receives stdin JSON with `current_response` and optional `history`, `review_mode`, and `last_user_msg`, it may classify the current FDR challenge cycle without launching Claude or Codex. This classifier is pure Ruby, shells out to nothing, reads no provider history, and emits only `judge.response.v1`. It covers the v2.5 cut-corners loop: first-cycle challenge, cut-corner admissions, explicit out-of-scope completion, denial/clean-verdict evasions, dismissive severity downgrades, repeated prior answers, review-mode detection from `last_user_msg`, and multi-line verdict/severity-pair matching. If stdin is absent, empty, malformed, has duplicate JSON object keys, or the provider route is unknown, the response remains canonical `unknown` under the rules below.

Protected runtime judge settings:

```
STRICT_CLAUDE_JUDGE_MODEL=claude-haiku-4-5-20251001
STRICT_CODEX_JUDGE_MODEL=gpt-5.3-codex-spark
STRICT_JUDGE_TIMEOUT_SEC=50
STRICT_NO_HAIKU_JUDGE=0
STRICT_NO_CODEX_JUDGE=0
```

These settings are accepted only through protected `runtime.env` or generated protected hook config after protected-baseline verification; provider tool environment cannot set or override them for the current turn. The judge backend is derived only from the verified active provider: Claude sessions use the Claude Haiku route, and Codex sessions use the Codex Spark route. v0 has no cross-provider `STRICT_JUDGE_PROVIDER` override. `STRICT_CLAUDE_JUDGE_MODEL` must be a protected-config value for an allowed Haiku judge model, and `STRICT_CODEX_JUDGE_MODEL` must be a protected-config value for an allowed Codex Spark judge model; a Sonnet/Opus/general GPT model or cross-provider backend value is invalid and maps the judge to `unknown`.

`STRICT_NO_HAIKU_JUDGE` and `STRICT_NO_CODEX_JUDGE` default to `0`. When a protected config explicitly sets the matching key to `1`, it acts as a backend-specific kill switch only. It makes `strict-judge` return `verdict:"unknown"` with a `judge-disabled` reason for the matching active provider; the Stop/FDR challenge caller must append the normal FDR cycle record under the session transaction. It never reroutes to the other provider, never disables artifact validation/import freshness, and never disables destructive, protected-root, approval, or Stop gates.

Protected judge prompt template:

- `<install-root>/config/judge-prompt-template.md` is an optional raw-text protected config loaded only after the protected install baseline is trusted.
- The template is prompt text for future fixture-proven judge invocation. It is not an executable extension point: strict-mode never shells, evals, sources, expands, or dispatches it as code.
- Markdown headers, blank lines, leading whitespace, and JSON-looking output-schema examples are preserved verbatim under the same whole-file byte cap as `user-prompt-injection.md`.
- If the file is missing, empty, malformed, or its protected baseline is untrusted, `strict-judge` must not use its bytes. A malformed or tampered template must not appear in stdout/stderr provider output or in `judge.response.v1`.
- The template cannot widen `judge.response.v1`. Even when the template contains JSON schema examples, `strict-judge` still returns exactly one canonical judge response object with the closed field set below.
- A future executable judge extension requires a separate `judge-extension` contract, explicit security spec, and fixture proof. `judge-prompt-template.md` deliberately does not establish executable protected config semantics.

Claude invocation target form, enabled only after the matching `judge-invocation` fixture proves the prompt-delivery and flag contract:

```bash
STRICT_MODE_NESTED=1 STRICT_MODE_NESTED_TOKEN="$NESTED_TOKEN" claude -p \
  --model "$STRICT_CLAUDE_JUDGE_MODEL" \
  --strict-mcp-config \
  --tools "" \
  -- "$PROMPT"
```

Codex invocation target form, enabled only after the matching `judge-invocation` fixture proves the prompt-delivery and flag contract:

```bash
STRICT_MODE_NESTED=1 STRICT_MODE_NESTED_TOKEN="$NESTED_TOKEN" codex exec \
  --model "$STRICT_CODEX_JUDGE_MODEL" \
  --skip-git-repo-check \
  --ephemeral \
  --sandbox read-only \
  --ask-for-approval never \
  < "$PROMPT_FILE"
```

Nested judge invocation must not dirty the user's normal Claude/Codex session, transcript, history, or hook-state files. The `judge-invocation` fixture must prove one of two exact behaviors for the installed provider: the chosen flags create no provider session/history writes, or all such writes are confined to a strict-mode-owned temporary provider state root that is deleted before `strict-judge` returns. The fixture records the provider state paths or environment variables used for this proof. At runtime, `strict-judge` verifies the selected isolation mode before launch and snapshots the fixture-declared user provider state paths before and after the invocation; an unexpected write makes the judge response `unknown`, logs `judge-state-isolation-failed`, and disables further real judge calls for that provider/session until repair or reinstall. It must not retry without isolation.

Codex judge must not write session files if `--ephemeral` works in the user's installed version. If Codex still needs session storage and no fixture-proven isolated temporary state root is available, the router must return `unknown` rather than retrying in a way that can recurse, dirty user context, or block the user.

`PROMPT_FILE` is a protected temporary file created by `strict-judge` under a strict-mode-owned `0700` temp directory with file mode `0600`, no symlink path components, `O_EXCL` or equivalent no-follow creation, and cleanup on every return path after the invocation. The Codex prompt must not be passed as an unguarded positional argument. The default Codex judge path uses stdin. An argv prompt form such as `codex exec -- "$PROMPT"` is allowed only when a fixture for the installed Codex version proves the separator contract; otherwise `strict-judge` must return `unknown` rather than invoking Codex with a prompt that could be parsed as CLI flags.

Judge timeout policy:

- `strict-judge` must resolve `timeout` or `gtimeout` before invoking Claude or Codex.
- If no timeout command exists, return `unknown` and log `judge skipped: timeout unavailable`.
- The configured timeout must be lower than the provider Stop hook timeout by at least 10 seconds.
- Judge stderr/stdout logs are redacted and truncated per the logging policy.

Judge response contract:

- `strict-judge` returns exactly one canonical JSON object to `fdr-challenge.sh`; prose, markdown fences, multiple JSON objects, or trailing non-whitespace make the response `unknown`.
- The response has exactly these fields and no extras: `schema_version` (`1`), `verdict`, `reason`, `findings`, `reviewed_scope_digest`, `reviewed_artifact_hash`, `confidence`, `model`, `backend`, and `response_hash`.
- `verdict` is one of `clean`, `challenge`, or `unknown`. `findings` is an empty array for `clean` and `unknown`; for `challenge`, every finding contains exactly `severity`, `source`, and `message`. Judge finding `severity` is `critical`, `high`, `medium`, `low`, or `info`; `source` is `artifact`, `assistant-text`, or `scope-metadata`; `message` is non-empty UTF-8 text capped at 4096 bytes after redaction. `reviewed_scope_digest` and `reviewed_artifact_hash` must equal the current FDR challenge inputs. `confidence` is a finite canonical JSON decimal from `0` to `1`, with no exponent and at most three fractional digits. `response_hash` is SHA-256 over canonical response JSON with only `response_hash` set to an empty string.
- `reason` is coupled to `verdict`. `clean` uses exactly `reason="clean"`. `challenge` uses exactly `reason="challenge"`. `unknown` uses exactly one of `judge-disabled`, `judge-invocation-unverified`, `judge-state-isolation-failed-until-repair`, `timeout`, `nonzero-exit`, `invalid-output`, `empty-output`, or `parse-failure`. Unknown reasons outside this closed enum are invalid output, not new policy.
- Invalid JSON, missing fields, extra fields, scope/artifact hash mismatch, malformed finding fields, backend/model mismatch, timeout, nonzero exit, or empty output maps to `judge-unknown`. A nested judge may explain uncertainty only through `verdict:"unknown"`; it must not block Stop by emitting free-form text.

Nested judge guard:

```bash
STRICT_HOOK_STDIN_PATH="$(strict_buffer_stdin_once)"
if [[ "${STRICT_MODE_NESTED:-0}" = "1" ]]; then
  strict_validate_nested_judge_token "$STRICT_HOOK_STDIN_PATH" || unset STRICT_MODE_NESTED STRICT_MODE_NESTED_TOKEN
  [[ "${STRICT_MODE_NESTED:-0}" = "1" ]] && exit 0
fi
```

`strict-hook` must read stdin exactly once into a bounded in-memory buffer or protected temporary file before nested-token validation, because provider/session/cwd/project fields may be needed to validate the token. If a temporary file is used, it must be created under a strict-mode-owned `0700` temp directory with file mode `0600`, no symlink path components, `O_EXCL` or equivalent no-follow creation, and cleanup before hook exit; `STRICT_HOOK_STDIN_PATH` is an internal variable and provider tool environment cannot supply or override it. If the token is invalid, the same buffered payload is passed to normal provider verification and normalization; invalid nested env must not consume or discard hook input.

`STRICT_MODE_NESTED=1` alone is never trusted. `strict-judge` must generate a high-entropy nonce and write `nested-judge-<provider>-<session_key>-<nonce>.json` under protected state before invoking the nested provider with `STRICT_MODE_NESTED=1` and `STRICT_MODE_NESTED_TOKEN=<nonce>`. Nested token records are exact-schema JSON with no extra fields: `schema_version` (`1`), `provider`, `session_key`, `raw_session_hash`, `cwd`, `project_dir`, `judge_backend`, `judge_model`, `parent_pid`, `parent_process_start`, `allowed_child_pid`, `created_at`, `expires_at`, `token_hash`, and `record_hash`. `allowed_child_pid` is the expected nested provider child pid or `0` when unavailable before launch. `token_hash` is SHA-256 over canonical JSON containing the nonce, provider/session/raw-session/cwd/project tuple, judge backend/model, parent process identity, and expiry. `record_hash` is SHA-256 over canonical token record JSON with only `record_hash` set to an empty string. Token creation, cleanup, and any allowed-child-pid update are session-scoped trusted-state mutations under lock with ledger coverage.

Hook entrypoints skip only when the token record exists, has the exact schema, matches argv provider and judge backend, matches `token_hash` and `record_hash`, is within TTL, has protected permissions, has trusted ledger coverage, and the process ancestry check passes when the OS exposes enough information. If the nested provider payload exposes the same parent session id, session key and raw session hash must also match the token record. If the nested provider creates a new ephemeral session id, session mismatch is allowed only when cwd and project dir are proven to match the token record either from the buffered payload or from the hook process cwd plus project-dir resolver; if cwd/project cannot be proven, nested skip is denied and normal enforcement continues. Invalid nested env is logged as attempted bypass and normal enforcement continues.

Nested judge token TTL must be shorter than the judge timeout and no longer than 120 seconds. Cleanup removes expired token records. Provider tools cannot create or edit nested token records because state root is protected.

---
