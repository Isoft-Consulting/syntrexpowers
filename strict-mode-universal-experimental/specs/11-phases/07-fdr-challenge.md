# Phase 7 — FDR Challenge

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: challenge suspicious clean verdicts and missing verdicts.

Deliverables:

- provider current-turn extraction in `tools/normalized_event_lib.rb`, including bounded `turn.assistant_text`, byte length, and truncation marker fields
- shared challenge state machine
- exact `fdr-cycles-*` JSONL schema and hash-chain validation
- judge router integration
- README provider support matrix entry for Codex FDR challenge proof status using closed provider-feature status/proof text

Acceptance:

- Claude behavior matches current Wave 2.5 baseline
- each provider is enabled only after current-turn extraction is proven for that installed provider version/build
- if provider current-turn extraction is not proven, README maps FDR challenge to the closed `disabled-until-proof` status; if it is proven, README maps FDR challenge to fixture-gated support and the fixture manifest binds the normalized assistant-text proof
- FDR challenge judge prompt contains only bounded current-turn assistant text, artifact/scope metadata, and no raw session history or raw transcript content; prompt hash inputs use the normalized assistant text byte length and truncation flag
- challenge cycles are bound to exact scope digest and capped without repeated judge invocation for the same unchanged scope
- meta-discussion self-bypass still requires no edits in current turn

---
