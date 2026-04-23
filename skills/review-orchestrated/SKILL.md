---
name: review-orchestrated
description: Review completed implementation against specs and rules. Spawns reviewer agents per phase, presents findings, then fixes mechanical violations with user approval.
argument-hint: <phase name or number, or blank for all completed phases>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
---

# Review Orchestrated

You are the top-level review coordinator. You read specs, spawn reviewer agents per phase, present consolidated findings, and fix mechanical violations with user approval.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to understand the full plan.
3. Read all phase spec files in `spec/` (files matching `spec/phase-*.md`).
4. Read the project's `CLAUDE.md` for project-specific rules.
5. Read `spec/progress.md` to determine what's been implemented and which tasks are complete.
6. Materialize shared context files for reviewer agents by running:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" review "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
   This copies rules and reviewer files to `spec/.context/` in a single command. Do NOT read the agent files yourself — the script handles it. The script always overwrites, so it is safe to run even if `spec/.context/` already exists from a prior `implement-hybrid` run.
7. If `$ARGUMENTS` specifies a phase, limit the review to that phase. Otherwise review all phases that have at least one completed task in `spec/progress.md`.

## Review Execution

### Determine Scope

From `spec/progress.md`, identify which phases have completed tasks. Group them by phase. Each phase becomes one review unit.

### Spawn Reviewers

For each phase in scope, spawn one reviewer Task **in parallel** as a background task. Build a lean reviewer prompt using the **"review-orchestrated → reviewer"** template from `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md`. Fill in phase details — the template now includes a `Report Path` field. Do not embed agent instructions — the reviewer reads them from `spec/.context/`.

Spawn each reviewer Task with:
- **subagent_type**: `claude-orchestrator:reviewer`
- **model**: `sonnet`
- **prompt**: the constructed prompt above
- **run_in_background**: `true`

Spawn all reviewer Tasks in a single message. Then call `TaskOutput(task_id, block=true)` for each to collect their lean summaries.

### Consolidate Findings

After all reviewer `TaskOutput` calls return:
1. Collect the lean summaries (tallies + critical findings).
2. Read the full report files from `spec/reviews/phase-{n}.md` for each phase reviewed.
   - If a report file is missing despite a successful `TaskOutput`, warn the user that the reviewer failed to write its report. Ask whether to re-run the review for that phase or proceed with the lean summary alone.
3. Present a consolidated summary to the user:
   - Per-phase verdict (clean / has-violations)
   - Total violation count, gap count, weak test count, legacy reference count (from lean summaries)
   - Full violation details organized by phase (from the report files)
4. If all phases are clean → report "All clean" and stop.

## Cleanup

If violations were found, do NOT fix them inline and do NOT split the flow into "approve mechanicals, then decide non-mechanicals one by one." Everything gets presented in one pass, all answers are collected in one batched `AskUserQuestion`, then fix agents are spawned to execute the work.

### 1. Classify Violations

Split all reported violations into two categories:

**Mechanical** — deterministic edit, no judgement:
- `# TODO`, `# FIXME`, `# HACK` comments → remove
- Commented-out code → remove
- `pytest.skip()`, `pytest.xfail()`, `unittest.skip` decorators → remove (the test must run)
- Dead imports (imports of removed modules/symbols) → remove
- Backwards-compatibility re-exports or aliases → remove
- Historical-provenance comments ("legacy", "fallback", "workaround", "temporary", "previously", "shim", "backwards compatible", "migrated from", "replaced") → delete the **code the comment decorates** along with the comment. The comment was placed by an agent that left dead or transitional code in place to avoid fixing tests. Removing only the comment while leaving the code is not a fix. If removing the code breaks tests, those tests were testing dead code and must be rewritten. This is still "mechanical" because the action is deterministic once identified — delete the decorated block — but a fix agent must do the deletion and fix collateral tests.

**Non-mechanical** — requires a decision or new implementation:
- Missing implementations (`pass`, `raise NotImplementedError`)
- Incomplete spec coverage (gaps)
- Weak test assertions that need rewriting
- Behavioural issues

### 2. Present Mechanical Violations as a Table

Show Mechanical violations in a single table. No approval request is made on this alone — the approval happens in the batched question in step 4.

| ID | File:Line | Rule Violated | Action |
|----|-----------|---------------|--------|
| M1 | src/foo.py:42 | TODO comment | Remove the comment |
| M2 | src/bar.py:10–28 | Historical-provenance comment decorates dead block | Delete the commented block and its decorator; rewrite `test_bar_legacy` |

### 3. Present Non-Mechanical Violations (compact with options)

For each Non-Mechanical violation, present in this compact format:

```
**{ID} — {short title}** ({severity})
{1–3 line description: what the spec requires, what's currently there, what decision is needed.}
Options:
  A) {concrete fix — one short line}
  B) {concrete fix — one short line}
  (C) {concrete fix — one short line, if a meaningfully distinct third path exists}
```

Full details (file path, line, quoted evidence, spec reference) stay in `spec/reviews/phase-{n}.md` — don't repeat them here.

### 4. Collect All Answers in One Batch

Issue a single `AskUserQuestion` call containing:
- One question: "Approve Mechanical fixes?" — choices: `all` / `subset (list IDs)` / `none`
- One question per Non-Mechanical violation: which option — choices: `A` / `B` / `C` / `skip` / `custom (user writes instruction)`

Do not proceed until every question has an answer. If the user picks `custom`, take their free-text instruction as the fix directive verbatim.

### 5. Batch and Spawn Fix Agents

Consolidate all approved fixes, grouped by target file (or by logically-related file cluster for non-mechanical fixes that span files). For each cluster, spawn one `claude-orchestrator:implementer` agent as a background Task. Spawn all fix agents in a single message, then collect results with `TaskOutput(task_id, block=true)`.

Each fix-agent prompt contains:
- The target file(s) to edit
- The list of approved Mechanical actions (from the table, verbatim)
- The list of resolved Non-Mechanical fixes (with the user's chosen option, or their custom instruction, as the edit directive)
- A directive to make ONLY the specified edits, run any affected tests locally, and return a summary of what changed plus any tests that now fail

Do not edit files yourself. Your job after spawning is to collect the summaries.

## Verification

After all fix agents have returned their summaries:

1. Run the project's test suite. Check `spec/plan.md` and `CLAUDE.md` for the test command. Common commands:
   ```bash
   # Try these in order until one works
   pytest
   npm test
   cargo test
   go test ./...
   ```
2. If tests pass → report success.
3. If tests fail → present failures to the user alongside the fix-agent summaries. Failures may indicate:
   - A mechanical fix that removed something load-bearing (the user decides whether to revert or rewrite the affected test)
   - A non-mechanical fix that introduced a regression
   - A pre-existing failure unrelated to this review
   Do not unilaterally revert. Ask the user how to proceed.

## Report

Present a final summary:
- Phases reviewed
- Violations found (by category)
- Mechanical fixes applied / skipped
- Non-mechanical fixes applied (with chosen option) / skipped
- Any fix-agent failures or partial applications
- Test results after fixes

## Context Conservation

You are a coordinator. Protect your context:
- **ALWAYS use `run_in_background: true` on Task calls.** This prevents full Task return values from flooding your context. After spawning, use `TaskOutput(task_id, block=true)` to wait for completion and retrieve only the lean return value.
- **Use `TaskOutput` with `block=true` only.** Never poll with `block=false` — it wastes context on partial output. Spawn the Task, then call `TaskOutput(task_id, block=true)` when you need the result.
- **Spawn-then-wait pattern:** For parallel execution, spawn multiple background Tasks in one message, then call `TaskOutput` for each in a subsequent message. For sequential execution, spawn one background Task and immediately `TaskOutput` it.
- **Do not read implementation files yourself.** Rely on reviewer reports for quality information.
- **Do not edit files yourself.** Fix agents apply all edits. Your role is classification, presentation, batching user answers, spawning, and post-run reporting.
- **Do not re-review after fixes.** The reviewer agents already identified the violations. Don't spawn another round of reviewers on the fix-agent output — trust the fix-agent summaries plus the test run.
- Read `spec/progress.md` for file lists, not git diffs.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands (including the materialize script invocation) MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths.
- **Use `/dev/null`**, never `NUL`.
- **Invoke scripts with `bash` explicitly** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh"`, not `./scripts/materialize-context.sh`.

## Important

- You MUST run the materialize script during setup (step 6). It always overwrites, so it is safe to run after `implement-hybrid`.
- Read `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md` once at the start to get the reviewer prompt template. Do not memorize it — refer back to the file when constructing each prompt.
- All reviewer prompts are lean pointers to `spec/.context/`. Never embed agent instructions or rules in prompts.
- Never queue a fix-agent edit for a non-mechanical violation without the user picking an option (or supplying their own). Skip it and mark it deferred in the final summary.
- The fix pass is no longer purely subtractive — non-mechanical fixes may add code, change logic, or rewrite test assertions per the user's chosen option. Mechanical cleanups remain subtractive (dead comments, dead code blocks, dead imports, skip decorators). Fix agents must respect this distinction per item.
