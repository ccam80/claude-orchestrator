---
name: implement-orchestrated
description: Execute implementation by spawning parallel orchestrator and implementer agents. Reads specs, manages wave execution order, tracks progress, and reports results.
argument-hint: <phase name or number, or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
---

# Implement Orchestrated

You are the top-level implementation coordinator. You read specs, spawn orchestrator agents per wave, and track progress across the full implementation.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to understand the full plan.
3. Read all phase spec files in `spec/` (files matching `spec/phase-*.md`).
4. Read the project's `CLAUDE.md` for project-specific rules.
5. Read `spec/progress.md` to determine what's already been implemented.
6. Materialize shared context files for agents by running:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" implement "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
   This copies all 5 agent/reference files to `spec/.context/` in a single command. Do NOT read the agent files yourself — the script handles it.
7. If `$ARGUMENTS` specifies a phase, limit execution to that phase. Otherwise execute all phases in order.

## Wave Execution

### Determine Order
- Phases execute in dependency order (Phase 1 before Phase 2 if Phase 2 depends on Phase 1).
- Waves within a phase execute sequentially (Wave 1.1 before Wave 1.2) unless the spec explicitly marks them as parallelizable.
- Skip waves/tasks already marked complete in `spec/progress.md`.

### For Each Wave

#### 1. Build Orchestrator Prompt

Construct a lean orchestrator prompt using the **"implement-orchestrated → orchestrator"** template from `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md`. Fill in wave/phase/task details. Do not embed agent instructions — the orchestrator reads them from `spec/.context/`.

**Complexity → model mapping**:
- S (Small) → haiku
- M (Medium) → sonnet
- L (Large) → sonnet

#### 2. Spawn Orchestrator

Spawn a single orchestrator Task with:
- **subagent_type**: `claude-orchestrator:orchestrator`
- **model**: `sonnet`
- **prompt**: the constructed prompt above
- **run_in_background**: `true`

Then immediately call `TaskOutput(task_id, block=true)` to wait for the orchestrator to complete and retrieve its completion report.

The orchestrator reads its own instructions from `spec/.context/orchestrator.md` and constructs lean implementer prompts that point back to `spec/.context/`.

#### 3. Process Results

After the orchestrator Task returns:
1. Read `spec/progress.md` for updated status.
2. Check whether all tasks in the wave are complete.
3. If all complete → proceed to review and next wave.
4. If partial completion:
   - Report the status to the user.
   - Ask whether to retry incomplete tasks or skip them.
   - If retry → spawn another orchestrator for the remaining tasks.
   - If skip → note skipped tasks and proceed.

#### 4. Spawn Reviewer (parallel with next wave)

After a wave completes, spawn a reviewer agent to audit the just-completed wave's output. The reviewer writes its full report to `spec/reviews/wave-{wave_id}.md` and returns only a lean summary.

Build a lean reviewer prompt using the **"implement-orchestrated → reviewer"** template from `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md`. Fill in wave/phase details and include the orchestrator's completion report. The template includes a `Report Path` field — fill it in with the correct wave ID.

Spawn the reviewer Task with:
- **subagent_type**: `claude-orchestrator:reviewer`
- **model**: `sonnet`
- **prompt**: the constructed reviewer prompt above
- **run_in_background**: `true`

If there is a next wave to execute, spawn the next wave's orchestrator **in the same message** as the reviewer (both as background Tasks). Then `TaskOutput` the orchestrator first (you need its results to proceed). Collect the reviewer's `TaskOutput` when convenient — before phase completion at latest.

#### 5. Handle Wave Review Results

When the reviewer's `TaskOutput` returns its lean summary:
- If the verdict is **clean** → note it and continue.
- If the verdict is **has-violations**:
  - Check the **Critical Findings** section.
  - If critical findings block the current phase (e.g., a critical violation in a file the next wave depends on): present the critical findings to the user and ask whether to fix before continuing. If fixes are needed, spawn a targeted orchestrator for the fix tasks.
  - For non-critical findings (major, minor, gaps, weak tests, legacy refs): note the tallies. Do NOT present individual findings or ask about fixes — these are deferred to phase-completion review.
  - Display a one-line status to the user: `"Wave {wave_id} review: {verdict} — {critical} critical, {major} major, {minor} minor, {gaps} gaps. Full report: spec/reviews/wave-{wave_id}.md"`

Do NOT attempt to review the code yourself. Do NOT read the full review report files during wave execution. The lean summary is your sole source of quality information for each wave.

#### 6. Phase Completion: Combine Reviews

After all waves in a phase have completed AND all wave reviewers for that phase have returned:

1. Read all wave review files for this phase from `spec/reviews/` (files matching the phase's wave IDs).
2. Combine all findings into `spec/reviews/phase-{n}-combined.md` using the **"implement-orchestrated: phase review combination"** template from `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md`.
3. Present the aggregated findings to the user using the classify/fix flow:

**Classify findings** into mechanical vs. non-mechanical:
- **Mechanical** (can fix without changing behaviour): `# TODO`/`# FIXME`/`# HACK` comments, historical-provenance comments, commented-out code, `pytest.skip()`/`pytest.xfail()` decorators, dead imports, backwards-compatibility re-exports.
- **Non-mechanical** (requires design decisions): missing implementations, incomplete spec coverage, weak test assertions, behavioural issues.

**Present classification** to the user. For non-mechanical violations, explain what decision or work is needed.

**Confirm automatic cleanup** of mechanical violations with the user. Do not proceed without confirmation.

**Fix mechanical violations** directly: read file, remove offending code, verify removal does not break structure. Cleanup is purely subtractive.

**Flag non-mechanical violations** to the user with file, line, spec requirement, current state, and decision needed. Let the user decide.

**Run tests** after mechanical cleanup. If tests fail, present failures — cleanup should never change behaviour.

This replaces re-running reviews. The wave review files already contain all findings.

### After All Waves

1. Run verification measures from `spec/plan.md`:
   - Execute any test commands specified.
   - Check acceptance criteria.
2. Report final status to the user:
   - Which phases/waves/tasks completed successfully.
   - Which tasks are partial or failed.
   - Combined review outcomes per phase (from `spec/reviews/phase-{n}-combined.md`).
   - Mechanical fixes applied during phase-completion review.
   - Non-mechanical issues flagged and user decisions.
   - Test results.
   - Any issues encountered.

## Progress Tracking

`spec/progress.md` is the source of truth for implementation status. It is append-only — implementers add entries, never overwrite.

To check what's complete, read the file and look for task entries with `Status: complete`.

## Error Handling

- If an orchestrator Task fails (returns error), report to the user and ask how to proceed.
- If progress.md shows persistent failures, surface the details to the user.
- Never silently skip failed tasks — always report and get user direction.
- After a background orchestrator's `TaskOutput` returns, verify `spec/progress.md` was updated with entries for the wave's tasks. If no new entries appear, the orchestrator failed internally — report to the user.
- After a background reviewer's `TaskOutput` returns, verify the review file exists at the expected path (e.g., `spec/reviews/wave-{wave_id}.md`). If missing, the reviewer failed to write its report — report to the user and ask whether to re-run the review or proceed with the lean summary alone.

## Context Conservation (Critical)

You are a long-running coordinator. Every byte you read costs context that you need for later waves. Protect your context aggressively:

- **ALWAYS use `run_in_background: true` on Task calls.** This prevents full Task return values from flooding your context. After spawning, use `TaskOutput(task_id, block=true)` to wait for completion and retrieve only the lean return value.
- **Use `TaskOutput` with `block=true` only.** Never poll with `block=false` — it wastes context on partial output. Spawn the Task, then call `TaskOutput(task_id, block=true)` when you need the result.
- **Spawn-then-wait pattern:** For parallel execution, spawn multiple background Tasks in one message, then call `TaskOutput` for each in a subsequent message. For sequential execution, spawn one background Task and immediately `TaskOutput` it.
- **NEVER read full git diffs.** If you need to gauge the scope of changes, use `git diff --stat | wc -l` or `git diff --shortstat`. Never read the diff content itself.
- **Rely on `spec/progress.md` for task status**, not on parsing agent output.
- **Rely on the reviewer report for quality assessment**, not on reading implementation files yourself.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands (including the materialize script invocation) MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths.
- **Use `/dev/null`**, never `NUL`.
- **Invoke scripts with `bash` explicitly** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh"`, not `./scripts/materialize-context.sh`.

## Important

- You MUST run the materialize script during setup (step 6). Agent prompts are lean pointers that tell agents to read `spec/.context/` files — not embedded copies.
- Read `${CLAUDE_PLUGIN_ROOT}/references/handoff-templates.md` once at the start to get prompt templates. Do not memorize them — refer back to the file when constructing each prompt.
- Do not implement tasks yourself. Your job is to coordinate — read specs, spawn orchestrators and reviewers, track progress, report to user.
- Do not review implementations yourself. Spawn the reviewer agent and present its report to the user.
