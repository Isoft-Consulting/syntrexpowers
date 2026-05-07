# 1. 7-Level Design

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


### Level 7 — Supersystem

The system runs inside local coding-agent hook runtimes:

- Claude Code hooks via `~/.claude/settings.json`
- Codex CLI hooks via `~/.codex/hooks.json` and `codex_hooks`
- Local shell, git worktrees, project `AGENTS.md`, user home state
- Optional nested headless judge invocations through Claude or Codex
- Optional nested bounded worker invocations through fixture-proven cheap provider models

Each runtime owns its own hook payload schema and blocking contract. The bundle must not assume that Claude and Codex expose identical lifecycle events.

### Level 6 — Mission

Provide a single strict-mode package that mechanically enforces quality, safety, and FDR discipline across Claude Code and Codex CLI without relying on model discipline or maintaining separate per-agent script forks.

### Level 5 — Concept

This is a universal strict-mode runtime adapter plus shared enforcement core.

It is:

- one installed package with one set of core scripts
- provider-aware at runtime
- adapter-driven at the hook boundary
- conservative when provider payloads are unknown
- experimental until Claude and Codex payload contracts are verified with fixtures

It is not:

- a rewrite of Claude Code or Codex
- a 1:1 parity guarantee in v0
- a separate Claude implementation plus separate Codex implementation
- a model prompt-only discipline system
- a hidden CI replacement

### Level 4 — Values

1. Single source of enforcement truth.
   Stub detection, destructive guards, FDR validation, and stop checks live once in `core/`.

2. Provider differences stay at the boundary.
   Claude/Codex differences are normalized before core logic runs.

3. Mechanical enforcement over reminders.
   Hooks block unsafe or incomplete work where the runtime supports blocking.

4. Fail-open only for uncertain semantic judgement, fail-closed for objective safety and freshness failures.
   A broken FDR judge should not trap a session forever; missing/stale artifacts, unresolved edit scope, stubs, protected-root writes, and matched destructive shell commands still block according to their gate contracts.

5. Idempotent install/uninstall.
   Re-running installer must not duplicate hooks or destroy user config.

6. Observable behavior.
   Unknown payloads, skipped checks, judge failures, and bypasses are logged.

7. Token economy through bounded evidence.
   Repeated instructions and broad project context should be replaced with compact hash-bound context packs, manifests, baselines, and FDR artifacts wherever a smaller proof is enough.

### Level 3 — Skills

The package can:

- detect current provider: `claude`, `codex`, or `unknown`
- normalize hook payloads into `StrictModeEvent`
- emit provider-compatible block/allow decisions
- inject strict-mode reminders on prompt submit where supported
- scan write/edit content for stubs before write where content is available
- scan changed files at stop time
- record edited changes with provider payloads plus git dirty-snapshot fallback
- gate destructive shell commands
- validate FDR artifacts
- decide trivial vs non-trivial git diffs
- route judge calls: Claude provider to Haiku, Codex provider to Spark
- route bounded file-level worker prompts to provider-appropriate cheap models when fixture-proven
- record worker context packs, invocations, and results as hash-bound advisory evidence
- guard nested judge calls with `STRICT_MODE_NESTED=1` plus a protected nested token
- install and uninstall Claude and Codex hook config entries

### Level 2 — Behaviors

Provider hook flow:

```
Claude/Codex invokes strict-hook --provider <provider> <logical-event>
  -> strict-hook reads stdin JSON
  -> provider argv/env/payload verification resolves runtime
  -> normalizer maps provider payload to StrictModeEvent
  -> core command runs against normalized event
  -> result maps to provider-specific output
```

Unknown payload with known provider flow:

```
strict-hook receives --provider <provider> but payload schema is incomplete or unknown
  -> write diagnostic log
  -> in Phase 0/log-only: capture fixture and do not enforce
  -> after enforcement is enabled: fail closed for write-like, permission, shell, and stop events whose trusted fields cannot be normalized
  -> for non-enforcing prompt/health/judge diagnostics: allow with warning
```

Truly unknown provider is a fixture-capture/manual mode only. It may return an internal destructive block for logging, but reliable enforcement requires provider-specific emission, so installed hooks must always pass `--provider`.

Judge flow:

```
core needs semantic judge
  -> strict-judge receives provider + task + prompt
  -> strict-judge creates a short-lived protected nested-run token
  -> Claude provider: claude -p with Haiku only after judge-invocation fixture proof
  -> Codex provider: codex exec with Spark only after judge-invocation fixture proof
  -> STRICT_MODE_NESTED=1 plus the protected token prevents recursive hooks
  -> non-zero or non-JSON judge output becomes audited semantic unknown; other Stop gates still apply
```

Bounded worker flow:

```
core or orchestrating provider needs narrow file-level assistance
  -> strict-mode builds a small context pack with explicit paths, excerpts, hashes, and task kind
  -> strict-worker invokes the provider-bound cheap worker route only after fixture proof
  -> worker returns a bounded JSON result: patch, findings, rewrite-suggestion, review-note, or unknown
  -> strict-mode records invocation/result hashes as advisory evidence
  -> any accepted code change still goes through normal provider tools, edit tracking, FDR, and Stop gates
```

Installer flow:

```
install.sh
  -> copies universal package to <install-root>/releases/<transaction-id>/
  -> writes protected runtime config defaults
  -> installs Claude hook config if ~/.claude exists or --provider claude/all
  -> installs Codex hook config if ~/.codex exists or --provider codex/all
  -> runs a recoverable activation commit for <install-root>/active and provider configs after staged self-check
  -> writes install manifest and protected install baseline for the active runtime
  -> preserves existing user hooks
  -> enables codex_hooks feature when writing Codex config
```

### Level 1 — Environment

Required local tools:

- `bash` 3.2+
- `jq`
- `git`
- `python3`
- `awk`
- `timeout` or `gtimeout` when semantic judge is enabled or when hook self-timeout cannot use native shell/Python deadline support

Provider tools:

- Claude judge: `claude`
- Codex judge: `codex`

If no timeout tool is available, installer must either disable semantic judge by default or fail with an actionable dependency message. Semantic judge must never run without a hard deadline.

Hook timeout policy:

- Every `strict-hook` invocation has a self-deadline independent of provider config timeout.
- Default protected self-timeouts are exact milliseconds by logical event: `session-start=5000`, `user-prompt-submit=3000`, `pre-tool-use=5000`, `post-tool-use=3000`, `stop=60000`, `subagent-stop=30000` when that event is fixture-proven and installed, and `permission-request=5000` when that event is fixture-proven and installed.
- The generated hook command passes `STRICT_HOOK_TIMEOUT_MS=<milliseconds>` as a literal environment assignment immediately before the quoted `<install-root>/active/bin/strict-hook` path. This assignment is trusted only because it is part of protected generated hook config and matches the protected install baseline; provider tool environment cannot override it.
- Installer fixture tests must prove the installed provider executes generated command strings with POSIX-style leading environment assignment and quoted path semantics, including an install root with spaces. If a provider exposes a native hook environment field instead, the installer may use that field only after fixture proof and protected-baseline recording. If neither form is verified, enforcing activation for that provider fails because `strict-hook` self-timeout cannot be trusted.
- If the provider supports hook timeout fields, installer writes both the provider-native outer timeout and the protected generated self-timeout value for `strict-hook`. The provider-native timeout must normalize to at least `STRICT_HOOK_TIMEOUT_MS + 1000` milliseconds for that event; equal or lower values are invalid because the provider could kill `strict-hook` before it emits a fail-closed decision. If provider-native units cannot express the guard gap, enforcing activation fails unless fixture proof says the provider has no native timeout field and `strict-hook` self-timeout is the only available deadline.
- If the provider does not support hook timeout fields, `strict-hook` still enforces its own deadline and returns the safest event-specific decision: destructive/protected pre-tool checks fail closed; post-tool logs and allows; stop emits a timeout block only when provider block format is verified. A provider without verified Stop block output may run Stop only in discovery/log-only mode; enforcing v0 activation fails rather than logging a degraded timeout and allowing final response.
- If the self-deadline fires before a required trusted-state transaction commits and re-verifies its ledger coverage, that transaction is treated as uncommitted. Enforcing `pre-tool-use` and `permission-request` emit the fixture-verified block/deny decision for `hook-self-timeout`; enforcing `stop` emits the fixture-verified block/continuation decision rather than allow. `post-tool-use`, prompt, and health events may return the safest provider-compatible allow/no-op only after leaving no trusted partial record behind; later Stop must treat the missing tool/edit evidence as unresolved or untrusted rather than silently accepting it.
- Semantic judge timeout must be lower than Stop self-timeout by at least 10 seconds.

State roots:

- Package install root: default `~/.strict-mode`
- Shared state root: default `~/.strict-mode/state`
- Shared config root: default `~/.strict-mode/config`
- Provider config targets:
  - Claude: `~/.claude/settings.json`
  - Codex: `~/.codex/hooks.json`, `~/.codex/config.toml`

Project opt-outs:

- Project quality-gate disable: `<project>/.strict-mode/disabled`
- Static prepass disable: `<project>/.strict-mode/no-static-prepass`
- Destructive gate disable: `<project>/.strict-mode/no-destructive-gate`

Legacy Claude opt-out paths such as `<project>/.claude/strict-mode.disabled` are disabled by default in universal v0. If `STRICT_LEGACY_CLAUDE_OPTOUTS=1` enables compatibility, legacy paths are treated as protected project opt-out files and must follow the same baseline, pending approval, exact phrase, and integrity rules as `<project>/.strict-mode/*`. No legacy path may bypass those rules.

Project opt-out files are accepted automatically only when their path and fingerprint were present in the immutable `session-baseline-<provider>-<sid>.json` captured at `session-start` or, if `session-start` is unavailable, at a fixture-proven first `user-prompt-submit` before any model tool execution. Per-turn baseline capture must distinguish the previous trusted baseline from the current filesystem capture; a file first observed in the current capture is not treated as pre-existing merely because it is written into `turn-baseline-<provider>-<sid>.json`. Files created or modified during the current turn are ignored for that turn and logged as attempted self-bypass. If an opt-out first appears after the immutable session baseline, `strict-hook` writes `pending-optout-<provider>-<sid>-<hash>.json` using the exact pending approval schema and appends an exact-schema `optout-log.jsonl` `pending` record with the hook source that observed it (`user-prompt-hook` or `stop-hook`) in the same mixed global/session transaction. The opt-out remains inactive until a later `user-prompt-submit` explicitly approves that opt-out path. Approval appends an exact-schema `optout-log.jsonl` `approved` record with `source=user-prompt-hook`. This prevents delayed self-bypass across adjacent turns. This applies to project quality-gate disable, static prepass disable, and destructive gate disable files.

Opt-out approval is exact-phrase based. The pending block reason must tell the agent to ask the user for `strict-mode approve-optout <hash>`. `strict-hook user-prompt-submit` creates the approval only when a trimmed line in the user prompt exactly equals that phrase and the hash matches a pending opt-out for the same provider, session key, raw session hash, cwd, project dir, opt-out path, opt-out fingerprint, pending record hash, and exact `next_user_prompt_marker`. Generic affirmations such as `yes`, `ok`, or `да` must not approve opt-outs. Pending opt-out approval expires after `STRICT_CONFIRM_MAX_AGE_SEC` (default 600 seconds).

Active opt-out evaluation must re-read the current opt-out file before each decision. An opt-out is active only when the current file exists at the same normalized path, has no symlink path components, is inside the resolved project opt-out location, has protected permissions, and its current fingerprint exactly matches either the immutable session-baseline fingerprint or an exact-schema `optout-log.jsonl` `approved` record for the same provider/session/raw-session/cwd/project/path/fingerprint tuple. If the file is deleted, replaced, chmod-unsafe, symlinked, or modified to a new fingerprint, the old baseline or approval no longer activates it. A changed opt-out fingerprint follows the pending opt-out approval flow again; current-turn capture alone cannot reuse the old approval.

For project opt-out files, protected permissions mean a regular file, owned by the current uid when the OS exposes ownership, with no group/other write bits, no setuid/setgid/sticky bits, and parent project opt-out directory components that are not group/other writable. If ownership or mode cannot be read, the opt-out is chmod-unsafe and inactive. Provider-tool attempts to relax these permissions are protected-root violations.

Opt-out effect matrix:

| Opt-out file | May disable | Must never disable |
|---|---|---|
| `<project>/.strict-mode/disabled` | quality gates for that project: prompt reminder, static prepass, stop-time stub scan, missing FDR artifact gate, FDR challenge | protected-root enforcement, provider hook config protection, runtime/config/state integrity, destructive shell gate, permission-request destructive/protected gates, exact approval rules, audit logging, dirty-snapshot safety for shell-created edits |
| `<project>/.strict-mode/no-static-prepass` | post-tool static prepass warnings only | stop-time stub scan, FDR artifact validation, FDR challenge, destructive/protected gates, protected-root integrity |
| `<project>/.strict-mode/no-destructive-gate` | project-destructive pattern checks that are not protected-root, provider-hook, runtime/config/state, permission-request, or broad filesystem/network approvals | protected-root enforcement, provider hook config protection, runtime/config/state integrity, broad filesystem/network denial, confirmation/bypass/opt-out anti-forgery |

If an opt-out's scope is ambiguous, strict-mode uses the narrower interpretation and logs `optout scope narrowed`.

---
