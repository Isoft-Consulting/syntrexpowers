# 8.9 Trivial Diff Detector

Part of [Shared Core Components](../08-shared-core-components.md).


`core/is-trivial-diff.sh` classifies whether the current turn's edited scope is trivial enough to skip semantic FDR challenge.

Rules:

- Input is the provider-scoped edits JSONL plus current git diff for those paths.
- Deleted paths, schema changes, migrations, security-sensitive paths, and multi-file behavioral edits are non-trivial by default.
- Whitespace-only or formatting-only diffs may be trivial only when the detector can prove no semantic source lines changed.
- Unknown classification is non-trivial for FDR challenge purposes. Judge failures become audited semantic `judge-unknown` records and do not disable artifact validation or other Stop gates.
