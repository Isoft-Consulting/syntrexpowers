---
name: requesting-code-review
description: Use when completing tasks, implementing major features, or before merging to verify work meets requirements
---

# Requesting Code Review

Dispatch superpowers:code-reviewer subagent to catch issues before they cascade. The reviewer gets precisely crafted context for evaluation — never your session's history. This keeps the reviewer focused on the work product, not your thought process, and preserves your own context for continued work.

**Core principle:** Review early, review often.

## When to Request Review

**Mandatory:**
- After each task in subagent-driven development
- After completing major feature
- Before merge to main

**Optional but valuable:**
- When stuck (fresh perspective)
- Before refactoring (baseline check)
- After fixing complex bug

## How to Request

**1. Get git SHAs:**
```bash
BASE_SHA=$(git rev-parse HEAD~1)  # or origin/main
HEAD_SHA=$(git rev-parse HEAD)
```

**2. Mechanical pre-sweep (zero LLM tokens):**

Before dispatching the reviewer, run grep to collect candidates:
```bash
# Find numeric assertions that might have count mismatches
git diff $BASE_SHA..$HEAD_SHA -- '*.php' '*.ts' '*.py' | grep -n 'assertEquals\|assertCount\|assert.*==' | grep '[0-9]'

# Find vacuous assertions (assertTrue(true), empty asserts)
git diff $BASE_SHA..$HEAD_SHA | grep -n 'assertTrue(true)\|assertEquals(.*,.*)'

# Find skip/guard conditions
git diff $BASE_SHA..$HEAD_SHA | grep -n 'skip\|function_exists\|class_exists'
```

Include pre-sweep results in the reviewer prompt as "Phase 0 candidates — verify these first."

**3. Dispatch code-reviewer subagent:**

Use Task tool with superpowers:code-reviewer type, fill template at `code-reviewer.md`

**Placeholders:**
- `{WHAT_WAS_IMPLEMENTED}` - What you just built
- `{PLAN_OR_REQUIREMENTS}` - What it should do
- `{BASE_SHA}` - Starting commit
- `{HEAD_SHA}` - Ending commit
- `{DESCRIPTION}` - Brief summary

**4. Act on feedback:**
- Fix Critical issues immediately
- Fix High issues before proceeding
- Note Medium/Low issues for later
- Push back if reviewer is wrong (with reasoning)

## Example

```
[Just completed Task 2: Add verification function]

You: Let me request code review before proceeding.

BASE_SHA=$(git log --oneline | grep "Task 1" | head -1 | awk '{print $1}')
HEAD_SHA=$(git rev-parse HEAD)

[Run mechanical pre-sweep]
grep -n 'assertEquals\|assertCount' src/verify.ts | grep '[0-9]'
→ verify.ts:45: assertEquals(4, issues.length)
→ verify.ts:89: assertEquals(0, errors.length)

[Dispatch superpowers:code-reviewer subagent]
  WHAT_WAS_IMPLEMENTED: Verification and repair functions for conversation index
  PLAN_OR_REQUIREMENTS: Task 2 from docs/superpowers/plans/deployment-plan.md
  BASE_SHA: a7981ec
  HEAD_SHA: 3df7661
  DESCRIPTION: Added verifyIndex() and repairIndex() with 4 issue types
  PHASE_0_CANDIDATES: verify.ts:45 assertEquals(4, issues.length), verify.ts:89 assertEquals(0, errors.length)

[Subagent returns]:
  Issues:
    High: verify.ts:45 — assertEquals(4, ...) but IssueType enum has 5 values
    Medium: repair.ts:23 — no progress callback for long operations
  Verdict: Ready to merge with fixes

You: [Fix both issues]
[Continue to Task 3]
```

## Integration with Workflows

**Subagent-Driven Development:**
- Review after EACH task
- Catch issues before they compound
- Fix before moving to next task

**Executing Plans:**
- Review after each batch (3 tasks)
- Get feedback, apply, continue

**Ad-Hoc Development:**
- Review before merge
- Review when stuck

## Red Flags

**Never:**
- Skip review because "it's simple"
- Ignore Critical issues
- Proceed with unfixed Important issues
- Argue with valid technical feedback

**If reviewer wrong:**
- Push back with technical reasoning
- Show code/tests that prove it works
- Request clarification

See template at: requesting-code-review/code-reviewer.md
