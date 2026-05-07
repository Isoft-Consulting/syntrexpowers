# 8.1 Stub Scan

Part of [Shared Core Components](../08-shared-core-components.md).


Shared `core/stub-scan.sh` implements this exact behavior:

- PHP/Go/JS/TS source scanning
- TODO/FIXME/XXX/HACK detection
- not-implemented exception/panic detection
- exact ERE stub marker set:
  - universal: `\b(TODO|FIXME|XXX|HACK)\b`
  - later markers: `(дореал|доделат|допиш|потом сдела|реализу[ею] позже|implement later|fix later)`
  - PHP exception stubs: `throw[[:space:]]+new[[:space:]]+\\?[A-Za-z_]*Exception\([^)]*(not[[:space:]]+implemented|заглушк|stub|todo)`
  - PHP die stubs: `\bdie\([^)]*(stub|заглушк|todo|not[[:space:]]+implemented)`
  - Go panic stubs: `panic\([[:space:]]*"[^"]*(not[[:space:]]+implemented|TODO|todo|stub|заглушк)`
  - Go TODO marker: `//[[:space:]]*TODO[\(:]`
- JS/TS error stubs: `throw[[:space:]]+new[[:space:]]+Error\([^)]*(not[[:space:]]+implemented|TODO|stub|заглушк)`
- per-line `allow-stub:` bypass
- `stub-allowlist.txt` `finding <finding_digest>` entries using the protected config grammar in [Hook Event Matrix](../03-hook-event-matrix.md)

Provider-specific pre-write extraction is not allowed in `stub-scan.sh`. Extraction happens in normalizer or `core/pre-write-scan.sh` against normalized `tool`.

Stub bypass safety:

- `allow-stub:` comments and stub allowlist entries are accepted only when they existed in the turn baseline or are approved through the quality bypass flow.
- A current-turn edit that adds `allow-stub:` on the same line as a stub marker does not suppress the stub finding.
- If baseline comparison is unavailable for an edited file, `allow-stub:` on changed or newly added lines is ignored.
- Project/global stub allowlist files are protected config and cannot be modified through provider tools.
