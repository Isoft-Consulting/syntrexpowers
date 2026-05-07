# 8.10 Stop Orchestration

Part of [Shared Core Components](../08-shared-core-components.md).


`strict-hook stop` is the single stop orchestrator. It may call multiple core checks, but only `strict-hook` emits the provider decision.

Required order:

1. buffer hook stdin exactly once and validate nested-judge token against the buffered payload; a valid nested token exits immediately, and an invalid nested env continues with the same buffered payload
2. provider verification and payload normalization from the buffered payload
3. protected-root integrity verification
4. project opt-out validation against the session baseline and opt-out approval log
5. dirty snapshot refresh and edits-log merge, or import-freeze compare-only mode when a state-root FDR artifact exposes trusted freeze metadata
6. unresolved current-turn intent and missing direct edit-record validation
7. stop-time stub scan for existing edited files
8. FDR artifact gate and artifact validation
9. trivial diff classification for the edited scope
10. FDR challenge state machine, only for non-trivial edits and only when normalized current-turn fields are available; reused FDR challenge blocks expose the original blocking cycle hash as their bypass subject, but `bypassed` cycle records are deferred until final bypass consumption succeeds
11. quality-bypass matching plan for exact quality block subjects; this step verifies candidate approved bypasses but does not rename markers or append consumed state yet
12. pre-consumption decision aggregation; if any non-quality block exists, or any quality block lacks an exact approved bypass, Stop blocks and no bypass marker is consumed
13. final allow-side transaction: consume every matched quality bypass needed for this allow, append consumed audit/ledger evidence plus any gate-specific `bypassed`/resolved state, and advance safe allowed Stop boundaries in `turn-baseline-<provider>-<sid>.json` under lock
14. provider emission

Aggregation contract:

- No later `allow` can override an earlier `block`.
- Approved quality bypass consumption is not a later `allow`; it removes only the exact matching quality block in the final allow-side transaction. Non-quality blocks are never bypassable, and their presence prevents consuming otherwise matching quality bypass markers.
- Multiple block reasons are joined with `\n---\n`.
- Warnings are logged and appended after block reasons only when they help the next action.
- Provider emission happens once.
- Safe allowed Stop boundaries are advanced only for final allow decisions and only in the same locked transaction as any `resolved` or consumed-bypass audit/ledger records required for that allow. When more than one allow-side audit/cycle record is required, the turn-baseline update and its ledger record bind to the canonical allow-side audit batch hash. A failed consumption transaction leaves all matched quality blocks active and emits block, not allow.
- Stop checks must be idempotent; running the same Stop hook twice must not consume confirmation/bypass state except documented one-shot files.

---
