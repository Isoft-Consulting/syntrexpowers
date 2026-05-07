# 8.7 Static Prepass

Part of [Shared Core Components](../08-shared-core-components.md).


Runs from `post-tool-use` after edit recording when normalized `tool.file_changes` includes existing source files and static prepass is enabled.

Rules:

- Static prepass is a shared core check over normalized changed paths; it must not parse provider payloads.
- It may scan only files from `tool.file_changes` and existing provider-scoped edit-log entries available at post-tool time. Dirty-snapshot additions are stop-only.
- It writes warnings and fired-hash records, but `post-tool-use` still exits allow.
- Stop-time checks remain authoritative; a static prepass warning never replaces a Stop block.
- It respects `<project>/.strict-mode/no-static-prepass` only when that opt-out is active under the baseline and pending-approval rules.

