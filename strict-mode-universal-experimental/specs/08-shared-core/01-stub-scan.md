# 8.1 Stub Scan

Part of [Shared Core Components](../08-shared-core-components.md).


Shared Ruby module `tools/stub_detection_lib.rb` implements this exact behavior (the earlier draft proposed a `core/stub-scan.sh` shell script; the current Ruby module reuses the same hook-runtime language as the rest of strict-hook and is invoked from the destructive-gate classifier through `tools/destructive_gate_lib.rb#classify_stub_content`):

- PHP/Go/JS/TS source scanning (file extensions `php`, `go`, `js`, `jsx`, `ts`, `tsx`, `mjs`, `cjs`)
- TODO/FIXME/XXX/HACK detection
- not-implemented exception/panic detection
- exact stub marker set (Ruby `Regexp` ports of the original ERE patterns):
  - universal: `\b(TODO|FIXME|XXX|HACK)\b`
  - later markers: `(дореал|доделат|допиш|потом сдела|реализу[ею] позже|implement later|fix later)` (case-insensitive)
  - PHP exception stubs: `throw\s+new\s+\\?[A-Za-z_]*Exception\([^)]*(not\s+implemented|заглушк|stub|todo)` (case-insensitive)
  - PHP die stubs: `\bdie\([^)]*(stub|заглушк|todo|not\s+implemented)` (case-insensitive)
  - Go panic stubs: `panic\(\s*"[^"]*(not\s+implemented|TODO|todo|stub|заглушк)` (case-insensitive)
  - Go TODO marker: `//\s*TODO[\(:]`
- JS/TS error stubs: `throw\s+new\s+Error\([^)]*(not\s+implemented|TODO|stub|заглушк)` (case-insensitive)
- `stub-allowlist.txt` `finding <finding_digest>` entries using the protected config grammar in [Hook Event Matrix](../03-hook-event-matrix.md)
- per-line `allow-stub:` bypass — defined here for future Stop-time scanner; at pre-write classifier time it is intentionally ignored per the Stub bypass safety rules below, because pre-write has no turn baseline available

Provider-specific pre-write extraction lives outside the scanner. `stub_detection_lib.rb#extract_scannable_targets` reads kind-based scannable targets (`write` kind → tool `content`, `edit` kind → tool `new_string`) from the normalized `tool`, and `#extract_raw_targets` reads MultiEdit `edits[]` joined content plus apply_patch Add/Update File `+`-prefixed lines from the raw provider payload. `classify_stub_content` merges both sources, deduplicates by `(file_path, sha256(content))`, and feeds the resulting targets together with the protected `stub-allowlist.txt` hash set into `stub_detection_lib.rb#scan`.

Stub bypass safety:

- `allow-stub:` comments and stub allowlist entries are accepted only when they existed in the turn baseline or are approved through the quality bypass flow.
- A current-turn edit that adds `allow-stub:` on the same line as a stub marker does not suppress the stub finding.
- If baseline comparison is unavailable for an edited file, `allow-stub:` on changed or newly added lines is ignored.
- Project/global stub allowlist files are protected config and cannot be modified through provider tools.
