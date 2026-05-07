# 8.2 Pre-Write Scan

Part of [Shared Core Components](../08-shared-core-components.md).


Runs on `pre-tool-use` when normalized `tool.kind` is `write`, `edit`, `multi-edit`, or `patch`.

Modes:

- `content` mode: scan `tool.content` or joined `tool.new_string` values.
- `patch` mode: scan added lines from unified patch.
- `unknown-content` mode: when write intent and target paths are already proven but the new content/patch body is not fixture-extractable, allow pre-tool and rely on stop-time disk scan.

Codex `apply_patch` is expected to use `patch` mode. If patch content parsing is uncertain, do not block for stubs pre-tool solely because the stub scanner lacks content; stop-time scan remains authoritative. This does not relax write-intent, tool-intent, or protected-path enforcement: target paths and write intent must still be normalized before execution, or the protected-path gate blocks in enforcing mode.
