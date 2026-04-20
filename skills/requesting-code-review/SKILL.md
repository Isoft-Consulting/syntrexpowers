---
name: requesting-code-review
description: Use when completing tasks, implementing major features, or before merging to verify work meets requirements
---

# Requesting Code Review

Dispatch syntrexpowers:code-reviewer subagent to catch issues before they cascade. The reviewer gets precisely crafted context for evaluation — never your session's history. This keeps the reviewer focused on the work product, not your thought process, and preserves your own context for continued work.

**Core principle:** Review early, review often.

## Review Modes

Use `strict` by default:
- merge gates
- bugfix validation
- regression review
- "find real issues only"

Use `mentor` only when the human explicitly asks for:
- strengths
- recommendations
- broader engineering feedback
- architecture notes
- "review like canonical superpowers"

If the human does not ask for advisory feedback, stay in `strict` mode.
Do not auto-upgrade to `mentor`.

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

Before dispatching the reviewer, run grep on changed files to collect candidates:
```bash
# Numeric assertions — potential count mismatches
git diff --name-only -z "$BASE_SHA..$HEAD_SHA" |
  while IFS= read -r -d '' file; do
    grep -HnE 'assertEquals\([^)]*\b[0-9]+\b|assertCount\([^)]*\b[0-9]+\b' -- "$file"
  done

# Vacuous assertions — tests that assert nothing
git diff --name-only -z "$BASE_SHA..$HEAD_SHA" |
  while IFS= read -r -d '' file; do
    grep -Hn 'assertTrue(true)' -- "$file"
  done

# Skip/guard conditions
git diff --name-only -z "$BASE_SHA..$HEAD_SHA" |
  while IFS= read -r -d '' file; do
    grep -Hn 'function_exists\|class_exists\|markTestSkipped' -- "$file"
  done

# TODO/FIXME
git diff --name-only -z "$BASE_SHA..$HEAD_SHA" |
  while IFS= read -r -d '' file; do
    grep -Hn 'TODO\|FIXME' -- "$file"
  done
```

Include pre-sweep results in the `{PHASE_0_CANDIDATES}` placeholder.

**3. Dispatch code-reviewer subagent:**

Use Task tool with syntrexpowers:code-reviewer type, fill template at `code-reviewer.md`

When dispatching:
- Default to `REVIEW_MODE: strict`
- Use `REVIEW_MODE: mentor` only on explicit request
- Set `OPTIONAL_FOCUS: none` when no advisory extras were requested
- Keep findings and verdict first in all modes
- Never mix advisory comments into `Issues`
- Findings are mandatory and proof-based. Advisory sections are optional and must never be presented as findings.

**Placeholders:**
- `{WHAT_WAS_IMPLEMENTED}` - What you just built
- `{PLAN_OR_REQUIREMENTS}` - What it should do
- `{BASE_SHA}` - Starting commit
- `{HEAD_SHA}` - Ending commit
- `{DESCRIPTION}` - Brief summary
- `{PHASE_0_CANDIDATES}` - Results from mechanical pre-sweep (step 2)
- `{REVIEW_MODE}` - `strict` by default; use `mentor` only if the human explicitly asks for advisory feedback
- `{OPTIONAL_FOCUS}` - Requested extras, e.g. `strengths`, `recommendations`, `architecture notes`; use `none` when not requested

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
git diff --name-only -z "$BASE_SHA..$HEAD_SHA" |
  while IFS= read -r -d '' file; do
    grep -HnE 'assertEquals\([^)]*\b[0-9]+\b|assertCount\([^)]*\b[0-9]+\b' -- "$file"
  done
→ verify.ts:45: assertEquals(4, issues.length)
→ verify.ts:89: assertEquals(0, errors.length)

[Dispatch syntrexpowers:code-reviewer subagent]
  WHAT_WAS_IMPLEMENTED: Verification and repair functions for conversation index
  PLAN_OR_REQUIREMENTS: Task 2 from docs/superpowers/plans/deployment-plan.md
  BASE_SHA: a7981ec
  HEAD_SHA: 3df7661
  DESCRIPTION: Added verifyIndex() and repairIndex() with 4 issue types
  PHASE_0_CANDIDATES: verify.ts:45 assertEquals(4, issues.length), verify.ts:89 assertEquals(0, errors.length)
  REVIEW_MODE: strict
  OPTIONAL_FOCUS: none

[Subagent returns]:
  #### High
    Source: verify.ts:45
    Path: verifyIndex() called with 5 issue types → assertion fails
    Claim vs reality: assertEquals(4, ...) but IssueType enum has 5 values
    Harm: test passes with wrong count, real coverage gap
    Fix: update expected count to match the enum
  #### Medium
    Source: repair.ts:23
    Path: repairIndex() on 10k+ entries → no feedback for minutes
    Claim vs reality: no progress callback for long operations
    Harm: user thinks process hung
    Fix: emit periodic progress updates during long runs
  Verdict: Needs fixes

You: [Fix both issues]
[Re-dispatch reviewer for confirmation]

[Subagent returns]:
  0 issues found
  Verdict: Ready to merge

[Continue to Task 3]
```

### Mentor-Mode Example

If the human explicitly asks for broader feedback, opt in:

```text
[Human asks]: "Review this and include strengths and recommendations."

[Dispatch syntrexpowers:code-reviewer subagent]
  REVIEW_MODE: mentor
  OPTIONAL_FOCUS: strengths, recommendations
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
- Proceed with unfixed High issues
- Argue with valid technical feedback

**If reviewer wrong:**
- Push back with technical reasoning
- Show code/tests that prove it works
- Request clarification

See template at: requesting-code-review/code-reviewer.md
