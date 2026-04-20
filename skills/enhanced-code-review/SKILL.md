---
name: enhanced-code-review
description: Use INSTEAD of superpowers:requesting-code-review and superpowers:code-reviewer. Use when completing tasks, implementing major features, requesting code review, or before merging. 9-layer + 7-vector review with proof model, mechanical pre-sweep, and compact findings-only output. Triggers on "code review", "review", "ревью", "проведи ревью", "фдр", "ФДР", "FDR", "full deep review".
---

# Enhanced Code Review

Replaces superpowers:requesting-code-review. 9-layer review with proof model, mechanical pre-sweep, and iterative fix cycle.

**When this skill triggers, do NOT also invoke superpowers:requesting-code-review or superpowers:code-reviewer.**

## Proof Model

A finding requires ALL THREE:
1. **Source** — file:line where problem exists
2. **Path** — reachable execution scenario
3. **Harm** — what breaks or degrades

Missing any → not a finding → do not report.

## Flow

```
1. Scope: determine what to review (auto, do NOT ask user)
   - User gave file paths → use them
   - Session context exists → files from Edit/Write/Read in this session
   - User named area ("в речекере", "в парсерах") → find files matching that area from session context or project structure
   - NEVER run git diff to guess scope
   - NEVER ask user "какие файлы?" — scope is always derivable from context
2. Phase 0: mechanical pre-sweep (grep, zero LLM tokens)
3. Review: apply 9-layer + vector protocol directly (do NOT dispatch subagent)
   → iterative: verify → fix → re-sweep → 0
4. Show findings + verdict
```

## Phase 0: Mechanical Pre-Sweep

Before reading code, run Grep on scope files to build candidate list:

- Numeric assertions: `assertEquals`, `assertCount` with numbers
- Vacuous assertions: `assertTrue(true)`
- Skip/guard conditions: `function_exists`, `class_exists`, `markTestSkipped`
- TODO/FIXME markers

Use Grep tool, not Bash. Start review from these candidates.

## Review Protocol

Apply directly — do NOT dispatch a subagent. You ARE the reviewer.

### 9 Layers (vertical — each file)

| # | Layer | Key Question |
|---|-------|-------------|
| 1 | Requirements | Implementation matches what was asked? |
| 2 | Architecture | Proper boundaries, separation of concerns? |
| 3 | Logic | All branches correct? Edge cases? |
| 4 | Contracts | API signatures, validation, response formats? |
| 5 | Data | Schema, migrations, transactions, nullable? |
| 6 | Security | Auth, authorization, input validation, secrets? |
| 7 | Reliability | Failure handling, idempotency, concurrency? |
| 8 | Performance | N+1, unbounded queries, caching? |
| 9 | Tests | New paths covered? Test quality, not just existence? |

### 7 Vectors (horizontal — across files)

| # | Vector | What to trace | When |
|---|--------|---------------|------|
| 1 | Caller→Callee | Caller expectation vs callee behavior | 4+ files |
| 2 | Data flow | Input → transform → persist → output | 4+ files |
| 3 | Error propagation | Error at point A → user at point B | 4+ files |
| 4 | Cross-module impact | Scope changes affect code outside scope | 10+ files |
| 5 | State lifecycle | Transitions, cleanup, impossible states | 10+ files |
| 6 | Absence audit | What SHOULD exist but doesn't | 4+ files |
| 7 | Numerical parity | Every hardcoded count → verify vs source | always |

**Graduated depth:**
- 1-3 files: 9 layers + vector 7
- 4-10 files: 9 layers + vectors 1, 3, 6, 7
- 10+ files: 9 layers + all 7 vectors

### Test-Specific Checklist (when scope contains tests)
- Every numeric assertion → verify count against source
- Every file_exists/path → verify path exists
- Every skip/mock condition → verify correctness
- Test count in docs → verify against actual test() calls

### Token Discipline
1. Grep first → candidate shortlist
2. Pointed reads: 20-80 lines around candidates
3. Caller chains: only when needed for proof
4. Do NOT read files top-to-bottom. Do NOT narrate clean areas.

### Iterative Cycle
1. Verify Phase 0 candidates (targeted reads)
2. Broad 9-layer + vector sweep
3. Fix confirmed findings
4. Re-sweep → repeat until 0

### Output Contract

**For each finding (all three proof elements required):**
- Severity: Critical / High / Medium / Low
- Source: file:line
- Path: reachable execution scenario
- Claim vs reality
- Harm
- Fix (if not obvious)

**Verdict:** Ready to merge / Needs fixes / Blocked

**DO NOT include:** Strengths, Recommendations, "what was checked and found clean", coverage tables, praise.

**If 0 findings:** report "0 issues found" and verdict only.
