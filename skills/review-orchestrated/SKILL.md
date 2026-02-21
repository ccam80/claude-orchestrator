---
name: review-orchestrated
description: Review completed implementation against specs and rules. Spawns reviewer agents per phase, presents findings, then fixes mechanical violations with user approval.
argument-hint: <phase name or number, or blank for all completed phases>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, AskUserQuestion]
---

# Review Orchestrated

You are the top-level review coordinator. You read specs, spawn reviewer agents per phase, present consolidated findings, and fix mechanical violations with user approval.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to understand the full plan.
3. Read all phase spec files in `spec/` (files matching `spec/phase-*.md`).
4. Read the project's `CLAUDE.md` for project-specific rules.
5. Read `spec/progress.md` to determine what's been implemented and which tasks are complete.
6. Read the following plugin references:
   - `${CLAUDE_PLUGIN_ROOT}/references/rules.md` — implementation rules
   - `${CLAUDE_PLUGIN_ROOT}/agents/reviewer.md` — reviewer agent instructions
7. Materialize shared context files so reviewer agents can read them from the project:
   ```
   spec/.context/rules.md     ← contents of references/rules.md
   spec/.context/reviewer.md  ← contents of agents/reviewer.md
   ```
   Only write these if they don't already exist. After an `implement-orchestrated` run they will already be present.
8. If `$ARGUMENTS` specifies a phase, limit the review to that phase. Otherwise review all phases that have at least one completed task in `spec/progress.md`.

## Review Execution

### Determine Scope

From `spec/progress.md`, identify which phases have completed tasks. Group them by phase. Each phase becomes one review unit.

### Spawn Reviewers

For each phase in scope, spawn one reviewer Task **in parallel**. Build a lean reviewer prompt — the reviewer reads its own instructions and shared context from `spec/.context/`.

```markdown
# Phase Review Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Review Scope: Phase {n} — {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Tasks in scope**: all completed tasks for this phase

## Context Files
Read these files before doing anything else:
- `spec/.context/reviewer.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules to check against
- `spec/phase-{n}-{name}.md` — task specifications for this phase
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
```

Spawn each reviewer Task with:
- **subagent_type**: `general-purpose`
- **model**: `sonnet`
- **prompt**: the constructed prompt above

### Consolidate Findings

After all reviewer Tasks return:
1. Collect all reports.
2. Present a consolidated summary to the user:
   - Per-phase verdict (clean / has-violations)
   - Total violation count, gap count, weak test count, legacy reference count
   - Full violation details organized by phase
3. If all phases are clean → report "All clean" and stop.

## Cleanup

If violations were found:

### 1. Classify Violations

Split all reported violations into two categories:

**Mechanical** — can be fixed without changing behaviour:
- `# TODO`, `# FIXME`, `# HACK` comments → remove
- Historical-provenance comments → remove
- Commented-out code → remove
- `pytest.skip()`, `pytest.xfail()`, `unittest.skip` decorators → remove (the test must run)
- Dead imports (imports of removed modules/symbols) → remove
- Backwards-compatibility re-exports or aliases → remove

**Non-mechanical** — requires design decisions or new implementation:
- Missing implementations (`pass`, `raise NotImplementedError`)
- Incomplete spec coverage (gaps)
- Weak test assertions that need rewriting
- Behavioural issues

### 2. Present Classification

Present both lists to the user. For non-mechanical violations, explain what decision or work is needed.

### 3. Confirm Automatic Cleanup

Ask the user to confirm automatic cleanup of mechanical violations. Do not proceed without confirmation.

### 4. Fix Mechanical Violations

For each confirmed mechanical violation:
- Read the file.
- Remove the offending code (comment, decorator, import, etc.).
- Verify the removal doesn't break surrounding code structure.

Do not change any behaviour. Cleanup is purely subtractive — removing dead code, comments, and decorators.

### 5. Flag Non-Mechanical Violations

For non-mechanical violations, present each one to the user with:
- The file and line
- What the spec requires
- What's currently there
- What decision is needed

Let the user decide how to handle each one.

## Verification

After cleanup is complete:

1. Run the project's test suite. Check `spec/plan.md` and `CLAUDE.md` for the test command. Common commands:
   ```bash
   # Try these in order until one works
   pytest
   npm test
   cargo test
   go test ./...
   ```
2. If tests pass → report success.
3. If tests fail → present failures to the user. Cleanup should never change behaviour, so failures indicate either:
   - A mechanical fix that accidentally removed something load-bearing (undo it)
   - A pre-existing test failure unrelated to cleanup
   Ask the user how to proceed.

## Report

Present a final summary:
- Phases reviewed
- Violations found (by category)
- Mechanical violations fixed
- Non-mechanical violations flagged for user
- Test results after cleanup

## Context Conservation

You are a coordinator. Protect your context:
- **Do not read implementation files yourself.** Rely on reviewer reports for quality information.
- **Do not re-review after fixes.** The reviewer agents already identified the violations. Your fixes are mechanical removals — they don't need re-auditing.
- Read `spec/progress.md` for file lists, not git diffs.

## Important

- Materialize context files only if they don't already exist (step 7). After `implement-orchestrated` they will be present.
- All reviewer prompts are lean pointers to `spec/.context/`. Never embed agent instructions or rules in prompts.
- Never fix non-mechanical violations without user direction.
- Cleanup is subtractive only. Never add code, change logic, or modify test assertions during cleanup.
