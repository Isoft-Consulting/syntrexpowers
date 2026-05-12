# Claude Fixtures

Real Claude Code hook fixtures must be captured before enforcing activation. The
fixture-manifest.json starts empty and is populated by running
`tools/import-discovery-fixture.rb` and `tools/import-contract-fixture.rb` against
captures from the installed Claude version.

Required fixture types per `specs/03-hook-event-matrix.md` and
`specs/11-phases/00-payload-discovery.md`:

- `payloads/` and `normalized/` plus `provider-proof/` for `session-start`,
  `user-prompt-submit`, `pre-tool-use`, `post-tool-use`, and `stop` —
  imported as `payload-schema` records via `tools/import-discovery-fixture.rb`.
- `command-execution/` discovery-record + stdout/stderr/exit-code triple for
  every generated hook event.
- `matcher/pre-tool-use/` discovery-record + matcher proof for `Bash`, `Write`,
  `Edit`, `MultiEdit`.
- `event-order/` proving `SessionStart` (or `UserPromptSubmit`) fires before the
  first `PreToolUse` of a turn, with stable session/cwd/project identity.
- `decision-output/pre-tool-use/<contract>.{provider-output.json,stdout,stderr,exit-code}`
  for the Claude `PreToolUse` block contract (exit `2`, reason on stderr per
  `specs/06-decision-contract.md:49`).
- `decision-output/stop/<contract>.{provider-output.json,stdout,stderr,exit-code}`
  for the Claude `Stop` block contract (stdout JSON
  `{"decision":"block","reason":"..."}` per `specs/06-decision-contract.md:50`).

Optional, captured only if proven for the installed Claude version:

- `SubagentStop` payload, command-execution, and decision-output fixtures.
  Without proof the installer must not register a `SubagentStop` hook entry
  (gated through `selected_output_contracts`; see
  `specs/11-phases/01-universal-install-skeleton.md:31`).
- `PermissionRequest` payload, command-execution, and decision-output fixtures.
  Required only when enforcing `permission-request` blocking is desired.

Capture procedure: enable `STRICT_CAPTURE_RAW_PAYLOADS=1` under a discovery-mode
strict-mode install, exercise the events from a Claude Code session, then run
`tools/plan-fixture-capture.rb --provider claude --provider-version
claude=<version>` for the exact importer commands.
