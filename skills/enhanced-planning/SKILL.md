---
name: enhanced-planning
description: Use TOGETHER WITH superpowers:writing-plans when creating implementation plans. Adds 7-level design validation, mechanical pre-checks, and structured verification steps. Triggers on "план", "plan", "implementation plan", "writing plan", "напиши план".
---

# Enhanced Planning

Augments superpowers:writing-plans with design validation and structured verification.

**Run superpowers:writing-plans as the primary process. This skill adds checks at key points.**

## Before Writing Plan

### Validate Design (7-Level Check)

Before breaking design into tasks, verify it passed design-review:
- All 7 levels defined for main module?
- Consistency checks pass?
- If not — run design-review skill first, fix gaps, then return to planning.

### Identify Mechanical Verification Points

For each planned task, define what can be verified mechanically (zero LLM cost):

```bash
# Tests pass
php tests/run.php

# File exists
ls -la path/to/expected/file

# Count matches
grep -c 'pattern' file

# No regressions
git diff --stat
```

Include these in each task's verification step.

## During Plan Writing

### Task Structure Enhancement

Each task in the plan should include:

1. **What** — standard (from superpowers:writing-plans)
2. **Files** — exact paths to create/modify
3. **Verification** — mechanical check commands (not just "run tests")
4. **Acceptance** — specific assertion: "file X contains Y", "test count = N"

### Cross-Task Consistency

After all tasks are drafted:
- Do task outputs chain correctly? (Task 2 needs output of Task 1?)
- Are there dependency gaps?
- Do numeric totals add up? (e.g., "26 tests" matches sum of per-file counts?)

## After Plan is Written

### Plan Self-Review Checklist

1. **Completeness** — every design feature has a task?
2. **No orphan tasks** — every task serves a design feature?
3. **Verification coverage** — every task has mechanical verification?
4. **Numeric parity** — all counts in plan match source of truth?
5. **No TODO/TBD** — all placeholders resolved?

## Integration with Superpowers

This skill does NOT replace superpowers:writing-plans. Flow:

```
superpowers:brainstorming → design-review (7 levels) → superpowers:writing-plans + enhanced-planning → implementation
```
