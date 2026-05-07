# Phase 7 — FDR Challenge

Part of [Phased Implementation](../11-phased-implementation.md).


Goal: challenge suspicious clean verdicts and missing verdicts.

Deliverables:

- provider current-turn extraction in `lib/normalize-event.sh`, including bounded `turn.assistant_text`, byte length, and truncation marker fields
- shared challenge state machine
- exact `fdr-cycles-*` JSONL schema and hash-chain validation
- judge router integration
- README provider support matrix entry for Codex FDR challenge proof status using closed provider-feature status/proof text

Acceptance:

- Claude behavior matches current Wave 2.5 baseline
- Codex enabled only after current-turn extraction is proven
- if Codex current-turn extraction is not proven, README maps Codex FDR challenge to the closed `disabled-until-proof` status; if it is proven, README links the fixture proof that enabled it
- FDR challenge judge prompt contains only bounded current-turn assistant text, artifact/scope metadata, and no raw session history or raw transcript content; prompt hash inputs use the normalized assistant text byte length and truncation flag
- challenge cycles are bound to exact scope digest and capped without repeated judge invocation for the same unchanged scope
- meta-discussion self-bypass still requires no edits in current turn

---
