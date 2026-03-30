---
name: implement-hybrid
description: Execute implementation by spawning implementers directly with state-based coordination. Eliminates the orchestrator management layer for better context efficiency while preserving spec-contract enforcement.
argument-hint: <phase name or number, or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
---

# Implement Hybrid

You are the implementation coordinator. You read specs, spawn implementer agents directly per wave, track progress via state files, and coordinate reviews. This eliminates the orchestrator middle layer for ~40-60% better context efficiency.

## Architecture: How This Differs from implement-orchestrated

```
implement-orchestrated (3 levels):        implement-hybrid (2 levels):
  coordinator                               coordinator (you)
    └─ orchestrator  ← ELIMINATED             └─ implementers (direct)
         └─ implementers                      └─ reviewer
    └─ reviewer
```

Savings per wave:
- No orchestrator setup (~4,700 tokens of agent file reads)
- No orchestrator monitoring context (~1,500 tokens per implementer round)
- Lighter materialization (3 files instead of 5)
- No handoff-templates.md read (templates are inline below)
- State-based recovery eliminates re-reading everything after context compression

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` — specifically the phase dependency graph and wave structure. Note phase order, wave sequences, and task complexities.
3. If `$ARGUMENTS` specifies a phase, limit execution to that phase. Otherwise execute all incomplete phases in dependency order.
4. Check for recovery state:
   - If `spec/.hybrid-state.json` exists, read it — resume from last incomplete wave.
   - Otherwise read `spec/progress.md` to determine what's already complete.
5. Read the phase spec file for the **first incomplete phase only** — not all specs. Read subsequent phase specs only when you reach them.
6. Read the project's `CLAUDE.md` for project-specific rules.
7. Materialize shared context files:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" hybrid "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
   This copies 3 files to `spec/.context/`: rules.md, lock-protocol.md, reviewer.md.
8. Initialize lock directories:
   ```bash
   mkdir -p "spec/.locks/tasks" "spec/.locks/files"
   ```
9. Initialize the state file to signal the first wave is clear to start:
   ```json
   {
     "phase": "{first_phase_id}",
     "wave": null,
     "completed_waves": [],
     "status": "verified",
     "verified": true,
     "verification": null,
     "last_updated": "{ISO 8601}"
   }
   ```
   Write this to `spec/.hybrid-state.json`.

### Verification Gate Hook

This plugin includes a PreToolUse hook (`scripts/verify-wave-gate.sh`) that acts as a hard safety net. It blocks implementer agent spawns whenever `spec/.hybrid-state.json` shows an unverified wave. This catches the coordinator even after context compression.

Register this hook in the consuming project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent",
        "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/verify-wave-gate.sh\""
      }
    ]
  }
}
```

**State machine** enforced by the hook and the coordinator:
```
verified ──→ implementing ──→ wave_complete ──→ verifying ──→ verified ──→ (next wave)
                                                          └─→ failed ──→ fixing ──→ verifying …
```

Only `verified` and `implementing` states allow new implementer spawns. All other states block.

## Test Baseline

Before spawning the first wave of implementers for each phase, capture the pre-existing test state. Spawn a lightweight background Task:

- **subagent_type**: `general-purpose`
- **model**: `haiku`
- **run_in_background**: `true`
- **description**: `"Capture test baseline"`

Use this prompt:

```markdown
# Test Baseline Capture

1. Read `CLAUDE.md` and `spec/plan.md` to find the project's test command.
2. Run the full test suite.
3. Write the results to `spec/test-baseline.md` in this format:

\```markdown
# Test Baseline
- **Timestamp**: {ISO 8601}
- **Phase**: {phase about to start}
- **Command**: {test command used}
- **Result**: {pass_count}/{total_count} passing, {fail_count} failing, {error_count} errors

## Failing Tests (pre-existing)
| Test | Status | Summary |
|------|--------|---------|
| {test_path::class::method} | FAIL/ERROR | {one-line summary} |
\```

If no test command is found, write that to the file and return. If tests cannot run (missing dependencies, etc.), document the error.
```

Wait for the baseline Task to complete via `TaskOutput(task_id, block=true)` before proceeding to wave execution. This ensures `spec/test-baseline.md` exists before any implementer reads it.

## Wave Execution

### Determine Order

- Phases execute in dependency order (from `spec/plan.md` dependency graph).
- Waves within a phase execute sequentially (Wave X.1 before X.2) unless the spec explicitly marks them as parallelizable.
- Skip waves/tasks already marked complete in `spec/progress.md`.

### For Each Wave

#### 1. Extract Tasks

Read the phase spec file and identify tasks in the current wave. For each task, note:
- Task ID, title, and complexity (S/M/L)

Filter out tasks already marked complete in `spec/progress.md`.

If all tasks in the wave are complete, skip to the next wave.

#### 2. Determine Parallelism

- Count remaining tasks in the wave.
- Set implementer count: `min(remaining_tasks, 4)`.
- Assign one task per implementer as their starting task. Include the full available task list so they can self-continue to additional tasks.

#### 3. Spawn Implementers

First, update state to `implementing`:
```json
{ "status": "implementing", "verified": false }
```
Write this to `spec/.hybrid-state.json` (merge with existing fields). This signals to the verification gate hook that a wave is actively running.

Spawn ALL implementers **in a single message** as background Tasks:

- **subagent_type**: `claude-orchestrator:implementer`
- **model**: S (Small) → `haiku`, M (Medium) or L (Large) → `sonnet`
- **run_in_background**: `true`
- **description**: short label, e.g. `"Implement {task_id}"`

Use this prompt template for each implementer:

```markdown
# Implementation Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec
- **Phase spec file**: spec/phase-{n}-{name}.md

## Your First Task: {task_id} — {task_title}

## Available Tasks (for self-continuation)
| ID | Title | Complexity |
|----|-------|------------|
{remaining tasks in wave, excluding tasks assigned to other implementers as first tasks}

## Context Files
Read these files before doing anything else:
- `spec/.context/rules.md` — implementation rules (non-negotiable, includes shell safety)
- `spec/.context/lock-protocol.md` — lock coordination protocol
- `spec/phase-{n}-{name}.md` — find your task by ID for full specification
- `CLAUDE.md` — project-specific rules and conventions
- `spec/test-baseline.md` — pre-existing test failures (check before investigating any test failure)
```

**Important**: The implementer's agent instructions are loaded automatically via the `claude-orchestrator:implementer` agent type. Do NOT add `spec/.context/implementer.md` to the context files list — it would be a redundant ~1,500 token read per agent.

After spawning all implementers in one message, call `TaskOutput(task_id, block=true)` for each in a follow-up message.

#### 4. Process Results

After all implementer Tasks return:
1. Read `spec/progress.md` for updated status — this is the source of truth, not implementer reports.
2. Check whether all tasks in the wave are complete.
3. If all complete → proceed to step 4a (commit), then step 7 (wave summary).
4. If partial → proceed to step 5 (retry).

#### 4a. Commit Wave

After verifying `spec/progress.md` has been updated for this wave, commit all changes:

```bash
git add -A
git commit -m "Wave {wave_id} implementation complete"
```

If the wave was only partially completed (after retries in step 5), use:

```bash
git add -A
git commit -m "Wave {wave_id} partial — {n}/{total} tasks complete"
```

This preserves state between waves so that if a subsequent wave fails or context compresses, prior work is safely committed.

#### 5. Handle Incomplete Tasks

If tasks remain incomplete after all implementers return:

1. Clean stale locks (locks left by returned implementers):
   ```bash
   # Check for remaining task locks
   ls "spec/.locks/tasks/" 2>/dev/null
   # Remove locks for tasks whose implementer has returned
   rm -rf "spec/.locks/tasks/{task_id}"
   ```
2. Re-read `spec/progress.md` to identify which tasks still need work.
3. Spawn new implementers for remaining tasks (same template as step 3).
4. Repeat until all tasks complete or max retries (3 rounds) reached.
5. If tasks still incomplete after 3 rounds: report to the user and ask how to proceed.

#### 6. Clean All Wave Locks

After all tasks complete (or max retries reached):
```bash
rm -rf "spec/.locks/tasks/"* "spec/.locks/files/"* 2>/dev/null
```

#### 7. Write Wave Summary and Update State → `wave_complete`

Append to `spec/progress.md` (NEVER overwrite — always append):

```markdown
---
## Wave {wave_id} Summary
- **Status**: complete | partial
- **Tasks completed**: {count}/{total}
- **Rounds**: {round_count}
```

Then **immediately** update `spec/.hybrid-state.json`:

```json
{
  "phase": "{current_phase_id}",
  "wave": "{completed_wave_id}",
  "completed_waves": ["X.1", "X.2"],
  "status": "wave_complete",
  "verified": false,
  "verification": null,
  "last_updated": "{ISO 8601}"
}
```

**This state blocks new implementer spawns via the verification gate hook.** The next wave cannot start until verification completes and the state transitions to `verified`.

#### 8. Spawn Reviewer (blocking)

Update state to `verifying`, then spawn the reviewer:

```json
{ "status": "verifying", "verified": false }
```

Build a reviewer prompt and spawn as a background Task:

- **subagent_type**: `claude-orchestrator:reviewer`
- **model**: `sonnet`
- **run_in_background**: `true`

Use this prompt template:

```markdown
# Wave Review Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Wave {wave_id}: {wave_name} (just completed)
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md

## Wave Completion Report
{lean summary: task IDs, statuses, test counts from step 4}

## Report Path
Write your full report to: `spec/reviews/wave-{wave_id}.md`

## Context Files
Read these files before doing anything else:
- `spec/.context/reviewer.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules to check against
- `spec/phase-{n}-{name}.md` — task specifications for the reviewed wave
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
```

**Wait for the reviewer to complete** via `TaskOutput(task_id, block=true)`. Do NOT spawn the next wave's implementers in parallel with the reviewer.

#### 9. Run Verification Tests

After the reviewer returns, run the project's test suite:

```bash
# Use the test command from CLAUDE.md / spec/plan.md
{test_command}
```

Capture the result: pass count, fail count, and whether any new failures appeared compared to `spec/test-baseline.md`.

#### 10. Evaluate Verification Gate

Collect three signals:
1. **Reviewer verdict**: from the lean summary (`clean` or `has-violations`)
2. **Critical findings count**: from the lean summary's Critical Findings section
3. **Test result**: pass/fail, any regressions vs baseline

**Gate decision**:

| Reviewer | Critical | Tests | Decision |
|----------|----------|-------|----------|
| clean | 0 | pass | **PASS** → step 11 |
| has-violations | 0 | pass | **PASS** → step 11 (non-critical findings deferred to phase review) |
| any | >0 | any | **FAIL** → step 10a |
| any | any | regression | **FAIL** → step 10a |

Display: `"Wave {wave_id} verification: {PASS|FAIL} — reviewer: {verdict}, critical: {n}, tests: {pass}/{total} ({n} regressions). Full report: spec/reviews/wave-{wave_id}.md"`

#### 10a. Handle Verification Failure (fix loop)

If the gate fails, enter the fix loop (max 2 rounds):

1. Update state:
   ```json
   { "status": "failed", "verified": false, "verification": { "reviewer_verdict": "...", "critical_findings": N, "test_regressions": N } }
   ```

2. **For critical review findings**: read ONLY the Critical Findings section from the reviewer's lean summary. Build targeted fix tasks.

3. **For test regressions**: identify which tests regressed vs baseline. Build targeted fix tasks.

4. Update state to `fixing`:
   ```json
   { "status": "fixing", "verified": false }
   ```

5. Spawn fix agents as background Tasks:
   - **subagent_type**: `claude-orchestrator:implementer`
   - **model**: `sonnet`
   - **run_in_background**: `true`
   - **description**: `"Fix-verify {wave_id} round {n}"` (the `fix-verify` prefix lets the hook distinguish fix agents from next-wave implementers — **the hook allows `fix-verify` spawns in any state**)

   Use the same implementer prompt template, but replace the task list with the specific fix tasks. Include the reviewer's critical findings and/or failing test names in the prompt.

6. Wait for fix agents via `TaskOutput(block=true)`.

7. Re-run verification: spawn a new reviewer for the wave (same template) and re-run tests. Evaluate the gate again.

8. If still failing after 2 fix rounds → report to user with the critical findings and test failures. Ask how to proceed. Do NOT continue to the next wave.

#### 11. Mark Verified and Proceed

Update state to `verified`:

```json
{
  "phase": "{current_phase_id}",
  "wave": "{completed_wave_id}",
  "completed_waves": ["X.1", "X.2"],
  "status": "verified",
  "verified": true,
  "verification": {
    "reviewer_verdict": "{clean|has-violations}",
    "critical_findings": 0,
    "tests_passed": true,
    "test_regressions": 0,
    "fix_rounds": 0
  },
  "last_updated": "{ISO 8601}"
}
```

**Only now** may you proceed to the next wave (back to step 1 for the next wave). The hook will allow implementer spawns in this state.

Do NOT attempt to review code yourself. Do NOT read the full review report files during wave execution — the lean summary is sufficient. Full reports are consumed at phase completion.

### Phase Completion

After all waves in a phase complete AND all wave reviewers return:

1. Read all wave review files for this phase from `spec/reviews/` (files matching the phase's wave IDs).
2. Combine all findings into `spec/reviews/phase-{n}-combined.md`:

```markdown
# Combined Review: Phase {n} — {phase_name}

## Summary
- **Waves reviewed**: {list of wave IDs}
- **Total violations**: {n} (critical: {n}, major: {n}, minor: {n})
- **Total gaps**: {n}
- **Total weak tests**: {n}
- **Total legacy references**: {n}
- **Verdict**: clean | has-violations

## Violations
{All violations from all wave reports, prefixed with wave ID}

### [Wave {wave_id}] {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical | major | minor

## Gaps
{All gaps from all wave reports}

## Weak Tests
{All weak tests from all wave reports}

## Legacy References
{All legacy references from all wave reports}
```

3. **Classify findings** into mechanical vs. non-mechanical:
   - **Mechanical** (fix without changing behaviour): `# TODO`/`# FIXME`/`# HACK` comments, historical-provenance comments, commented-out code, `pytest.skip()`/`pytest.xfail()` decorators, dead imports, backwards-compatibility re-exports.
   - **Non-mechanical** (requires design decisions): missing implementations, incomplete spec coverage, weak test assertions, behavioural issues.

4. **Present classification** to the user. For non-mechanical violations, explain what decision or work is needed.

5. **Confirm automatic cleanup** of mechanical violations with the user. Do not proceed without confirmation.

6. **Fix mechanical violations** directly: read file, remove offending code, verify removal does not break structure. Cleanup is purely subtractive.

7. **Flag non-mechanical violations** to the user with file, line, spec requirement, current state, and decision needed.

8. **Run tests** after mechanical cleanup. If tests fail, present failures — cleanup should never change behaviour.

### After All Phases

1. Run verification measures from `spec/plan.md` (test commands, acceptance criteria).
2. Report final status:
   - Phases/waves/tasks completed.
   - Combined review outcomes per phase.
   - Mechanical fixes applied.
   - Non-mechanical issues flagged.
   - Test results.
3. Clean up:
   ```bash
   rm -f "spec/.hybrid-state.json"
   rm -rf "spec/.locks/"
   ```

## Context Conservation (Critical)

You are a long-running coordinator. Protect your context aggressively:

- **ALWAYS `run_in_background: true`** on Task calls. This prevents full return values from flooding your context.
- **Use `TaskOutput(block=true)` only.** Never poll with `block=false`.
- **Spawn-then-wait**: For parallel execution, spawn multiple background Tasks in one message, then `TaskOutput` each in subsequent messages.
- **Never read full git diffs.** Use `git diff --shortstat` if needed.
- **Never read review report files during wave execution.** The lean summary is your sole source of quality information per wave. Read full reports only at phase completion for the combined review.
- **Read phase spec files once per phase**, not per wave. The spec is the same for all waves in a phase.
- **Read progress.md for current state** — scan for task completion markers, don't parse the full history.
- **State file enables recovery.** If context compresses mid-execution, re-read `spec/.hybrid-state.json` and `spec/progress.md` to determine exactly where to resume. You do not need to re-read prior wave results. The state file's `status` field tells you exactly what to do next:
  - `implementing` → implementers are running; wait for them (or check if they've already returned via progress.md).
  - `wave_complete` → implementation done but not verified; go to step 8 (spawn reviewer).
  - `verifying` → reviewer is running; wait for it (or check if review file exists).
  - `failed` → verification failed; go to step 10a (fix loop).
  - `fixing` → fix agents are running; wait for them.
  - `verified` → safe to proceed to next wave; go to step 1 for the next wave.

## Error Handling

- If an implementer Task fails (error return), report to user and ask how to proceed.
- If progress.md shows persistent failures across rounds, surface the details.
- Never silently skip failed tasks — always report and get user direction.
- After `TaskOutput` returns, verify `spec/progress.md` was updated with entries for the wave's tasks. If no new entries appear, the implementer failed internally — report to the user.
- After a reviewer's `TaskOutput` returns, verify the review file exists at the expected path. If missing, the reviewer failed — report to the user and ask whether to re-run or proceed with the lean summary alone.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths, never backslashes.
- **Use `/dev/null`**, never `NUL`.
- **Use Unix commands** (`ls`, `rm`, `mkdir`), never Windows commands.

## Important

- Run the materialize script during setup (Setup step 7). Implementer prompts are lean pointers to `spec/.context/` files.
- Do not implement tasks yourself. Your job is to coordinate.
- Do not review code yourself. Spawn the reviewer agent.
- The `claude-orchestrator:implementer` agent type provides full implementer instructions automatically. Do not redundantly point implementers to `spec/.context/implementer.md`.
- Rely on `spec/progress.md` as source of truth, not on parsing agent output.
