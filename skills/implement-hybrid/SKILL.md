---
name: implement-hybrid
description: Execute implementation by spawning implementers directly with state-based coordination. Eliminates the orchestrator management layer for better context efficiency while preserving spec-contract enforcement.
argument-hint: <phase name or number, or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
hooks:
  PreToolUse:
    - matcher: "Agent"
      hooks:
        - type: command
          if: "Agent(claude-orchestrator:implementer)"
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/gate-implementer.sh\""
  PostToolUse:
    - matcher: "Agent"
      hooks:
        - type: command
          if: "Agent(claude-orchestrator:wave-verifier)"
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/mark-verified.sh\""
---

# Implement Hybrid

You are the implementation coordinator. You read specs, spawn implementer agents directly per batch, track progress via state files, and coordinate verification. This eliminates the orchestrator middle layer for ~40-60% better context efficiency.

## Architecture

```
implement-orchestrated (3 levels):        implement-hybrid (2 levels):
  coordinator                               coordinator (you)
    └─ orchestrator  ← ELIMINATED             └─ implementers (direct)
         └─ implementers                      └─ wave-verifier
    └─ reviewer
```

## Verification Gate System

This skill uses a hook-enforced verification gate. You **cannot** bypass it — the hooks control the `verified` flag, not you.

**Two hooks registered via frontmatter:**

1. **PreToolUse on `claude-orchestrator:implementer`** — `gate-implementer.sh` blocks implementer spawns if any batch exists with `verified=false` and is not currently implementing. This catches you even after context compression.

2. **PostToolUse on `claude-orchestrator:wave-verifier`** — `mark-verified.sh` parses the verifier's output. Sets `verified=true` ONLY if the verifier returned `## Verdict: PASS`. On FAIL, sets `status=failed` and injects instructions.

**You cannot write `verified=true` yourself.** Only the PostToolUse hook can do this, and only when the wave-verifier returns PASS. Your job is to spawn the verifier after each batch completes.

### Batch State

The state file `spec/.hybrid-state.json` tracks batches, not individual waves:

```json
{
  "phase": "1",
  "batches": [
    {
      "id": "batch-1",
      "waves": ["1.1", "1.2"],
      "tasks": ["T1.1a", "T1.1b", "T1.2a"],
      "status": "verified",
      "verified": true
    },
    {
      "id": "batch-2",
      "waves": ["1.3"],
      "tasks": ["T1.3a", "T1.3b"],
      "status": "implementing",
      "verified": false
    }
  ],
  "last_updated": "2026-04-09T03:00:00Z"
}
```

A **batch** is one spawn group — all waves/tasks the spec says can run in parallel. Sequential waves each get their own batch. Parallel waves share a batch.

**Batch statuses:**
- `implementing` — implementers are running (gate allows more implementers for this batch)
- `implemented` — all implementers returned, awaiting verification (gate blocks new batches)
- `verifying` — wave-verifier is running (gate blocks new batches)
- `verified` — verifier returned PASS, hook set `verified=true` (gate allows new batches)
- `failed` — verifier returned FAIL, hook set `status=failed` (gate blocks new batches)

**Gate rule:** block new implementer spawns if ANY batch has `verified=false` AND `status != "implementing"`.

### If the Hook Blocks You

If you see a `BLOCKED:` message from the gate hook, you skipped verification. Do this:

1. Read `spec/.hybrid-state.json` to find the unverified batch.
2. If `status=implemented` — you need to spawn the wave-verifier (step 7).
3. If `status=failed` — read the verifier's Failure Summary, spawn fix agents, then re-verify (step 8).
4. If `status=verifying` — the verifier is still running. Wait for it via `TaskOutput(block=true)`.

Do NOT attempt to write `verified=true` yourself — the Write tool will succeed but the hook checks the verifier's actual output, and the next implementer spawn will be blocked because no verifier PASS occurred.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` — specifically the phase dependency graph and wave structure. Note phase order, wave sequences, and task complexities. Identify which waves can run in parallel.
3. If `$ARGUMENTS` specifies a phase, limit execution to that phase. Otherwise execute all incomplete phases in dependency order.
4. Check for recovery state:
   - If `spec/.hybrid-state.json` exists, read it — resume from the last incomplete batch.
   - Otherwise read `spec/progress.md` to determine what's already complete.
5. Read the phase spec file for the **first incomplete phase only** — not all specs. Read subsequent phase specs only when you reach them.
6. Read the project's `CLAUDE.md` for project-specific rules.
7. Materialize shared context files:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" hybrid "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
   This copies shared context files to `spec/.context/`.
8. Initialize lock directories:
   ```bash
   mkdir -p "spec/.locks/tasks" "spec/.locks/files"
   ```
9. Initialize the state file with an empty batches array:
   ```json
   {
     "phase": "{first_phase_id}",
     "batches": [],
     "last_updated": "{ISO 8601}"
   }
   ```
   Write this to `spec/.hybrid-state.json`.

## Test Baseline

Before spawning the first batch of implementers for each phase, capture the pre-existing test state. Spawn a lightweight background Task:

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

Wait for the baseline Task to complete via `TaskOutput(task_id, block=true)` before proceeding to batch execution. This ensures `spec/test-baseline.md` exists before any implementer reads it.

## Batch Execution

### Determine Batches

From the phase spec and `spec/plan.md`:
- Identify which waves can run in parallel (the spec marks these explicitly).
- Group parallel waves into a single **batch**.
- Sequential waves each get their own batch.
- Batches execute in order. Within a batch, all waves run concurrently.
- Skip waves/tasks already marked complete in `spec/progress.md`.

### For Each Batch

#### 1. Plan the Batch

Identify all tasks across all waves in this batch. For each task, note:
- Task ID, title, complexity (S/M/L), and which wave it belongs to.

Filter out tasks already marked complete in `spec/progress.md`.

If all tasks in the batch are complete, skip to the next batch.

#### 2. Create State Entry

Add a new batch entry to `spec/.hybrid-state.json`:

```json
{
  "id": "batch-{n}",
  "waves": ["X.1", "X.2"],
  "tasks": ["TX.1a", "TX.1b", "TX.2a"],
  "status": "implementing",
  "verified": false
}
```

Append this to the `batches` array. The `implementing` status signals to the gate that this batch is in-flight.

#### 3. Spawn Implementers

Determine parallelism: `min(remaining_tasks, 4)` implementers. Assign one task per implementer as their starting task. Include the full available task list so they can self-continue.

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
{remaining tasks in batch, excluding tasks assigned to other implementers as first tasks}

## Context Files
Read these files before doing anything else:
- `spec/.context/rules.md` — implementation rules (non-negotiable, includes shell safety)
- `spec/.context/lock-protocol.md` — lock coordination protocol
- `spec/phase-{n}-{name}.md` — find your task by ID for full specification
- `CLAUDE.md` — project-specific rules and conventions
- `spec/test-baseline.md` — pre-existing test failures (check before investigating any test failure)
```

After spawning all implementers in one message, call `TaskOutput(task_id, block=true)` for each in a follow-up message.

#### 4. Process Results

After all implementer Tasks return:
1. Read `spec/progress.md` for updated status — this is the source of truth, not implementer reports.
2. Check whether all tasks in the batch are complete.
3. If all complete → proceed to step 5 (commit), then step 6 (batch summary).
4. If partial → proceed to step 4a (retry).

#### 4a. Handle Incomplete Tasks

If tasks remain incomplete after all implementers return:

1. Clean stale locks:
   ```bash
   ls "spec/.locks/tasks/" 2>/dev/null
   rm -rf "spec/.locks/tasks/{task_id}"
   ```
2. Re-read `spec/progress.md` to identify which tasks still need work.
3. Spawn new implementers for remaining tasks (same template as step 3).
4. Repeat until all tasks complete or max retries (3 rounds) reached.
5. If tasks still incomplete after 3 rounds: report to the user and ask how to proceed.

#### 5. Commit Batch

After verifying `spec/progress.md` has been updated for this batch, commit all changes:

```bash
git add -A
git commit -m "Batch {batch_id} implementation complete — waves {wave_list}"
```

If partial (after retries):

```bash
git add -A
git commit -m "Batch {batch_id} partial — {n}/{total} tasks complete"
```

#### 6. Update State → `implemented`

Clean locks and append batch summary to `spec/progress.md`:

```bash
rm -rf "spec/.locks/tasks/"* "spec/.locks/files/"* 2>/dev/null
```

```markdown
---
## Batch {batch_id} Summary (waves: {wave_list})
- **Status**: complete | partial
- **Tasks completed**: {count}/{total}
- **Rounds**: {round_count}
```

Update the batch entry in `spec/.hybrid-state.json`:

```json
{ "status": "implemented", "verified": false }
```

**This state blocks new implementer spawns via the gate hook.** You must now verify this batch before starting the next one.

#### 7. Spawn Wave Verifier

Update the batch status to `verifying`:

```json
{ "status": "verifying", "verified": false }
```

Spawn the wave-verifier as a background Task:

- **subagent_type**: `claude-orchestrator:wave-verifier`
- **model**: `sonnet`
- **run_in_background**: `true`
- **description**: `"Verify batch {batch_id}"`

Use this prompt template:

```markdown
# Wave Verification Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Batch: {batch_id}
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Waves**: {wave_list}
- **Tasks**: {task_id_list}

## Test Command
{test_command from CLAUDE.md or spec/plan.md}

## Context Files
Read these files before doing anything else:
- `spec/phase-{n}-{name}.md` — task specifications (find each task by ID)
- `spec/.context/rules.md` — implementation rules to check against
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
- `spec/test-baseline.md` — pre-existing test failures
```

**Wait for the verifier to complete** via `TaskOutput(task_id, block=true)`.

The PostToolUse hook will fire automatically after the verifier returns:
- If verifier returned **PASS** → hook sets `verified=true`, `status=verified`. You will see `"hook success: Wave verification PASSED"`. Proceed to the next batch.
- If verifier returned **FAIL** → hook sets `status=failed`. You will see `"hook success: Wave verification FAILED"`. Go to step 8.

Display: `"Batch {batch_id} verification: {PASS|FAIL}"`

#### 8. Handle Verification Failure (fix loop)

If the verifier returned FAIL, enter the fix loop (max 2 rounds):

1. Read the verifier's output — specifically the **Failure Summary** section. This lists every reason for failure (missing spec elements, rule violations, test regressions).

2. Build targeted fix tasks from the failure reasons.

3. Spawn fix agents as background Tasks:
   - **subagent_type**: `claude-orchestrator:implementer`
   - **model**: `sonnet`
   - **run_in_background**: `true`
   - **description**: `"Fix batch {batch_id} round {n}"`

   **Important**: The gate hook blocks implementer spawns when a batch has `status=failed`. Before spawning fix agents, update the batch status to `implementing`:
   ```json
   { "status": "implementing", "verified": false }
   ```
   This allows the gate to pass for fix agents.

   Use the implementer prompt template, but replace the task list with the specific fix tasks. Include the verifier's failure reasons in the prompt.

4. Wait for fix agents via `TaskOutput(block=true)`.

5. Update status back to `implemented`, then re-verify: go back to step 7 (spawn wave-verifier again).

6. If still failing after 2 fix rounds → report to user with the verifier's Failure Summary. Ask how to proceed. Do NOT continue to the next batch.

#### 9. Proceed to Next Batch

After the hook sets `verified=true`, proceed to step 1 for the next batch. The gate will allow new implementer spawns.

### Phase Completion

After all batches in a phase are verified:

1. Update the phase field in state:
   ```json
   { "phase": "{next_phase_id}" }
   ```

2. Append phase summary to `spec/progress.md`:
   ```markdown
   ---
   ## Phase {n} Complete
   - **Batches**: {count}
   - **All verified**: yes
   ```

3. Continue to the next phase (back to Batch Execution for the new phase).

### After All Phases

1. Run verification measures from `spec/plan.md` (test commands, acceptance criteria).
2. Report final status:
   - Phases/batches/tasks completed.
   - Verification outcomes per batch.
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
- **Read phase spec files once per phase**, not per batch.
- **Read progress.md for current state** — scan for task completion markers, don't parse the full history.
- **State file enables recovery.** If context compresses mid-execution, re-read `spec/.hybrid-state.json` and `spec/progress.md` to determine exactly where to resume. The last batch's `status` tells you what to do next:
  - `implementing` → implementers are running; wait for them (or check progress.md).
  - `implemented` → batch done but not verified; go to step 7 (spawn wave-verifier).
  - `verifying` → verifier is running; wait for it.
  - `verified` → safe to proceed to next batch.
  - `failed` → verifier returned FAIL; go to step 8 (fix loop).

## Error Handling

- If an implementer Task fails (error return), report to user and ask how to proceed.
- If progress.md shows persistent failures across rounds, surface the details.
- Never silently skip failed tasks — always report and get user direction.
- After `TaskOutput` returns, verify `spec/progress.md` was updated with entries for the batch's tasks. If no new entries appear, the implementer failed internally — report to the user.
- After a verifier's `TaskOutput` returns, check the hook's injected context message. If you see `"hook success: Wave verification PASSED"` proceed normally. If you see `"hook success: Wave verification FAILED"` go to step 8. If you see the WARNING about unparseable verdict, report to the user.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths, never backslashes.
- **Use `/dev/null`**, never `NUL`.
- **Use Unix commands** (`ls`, `rm`, `mkdir`), never Windows commands.

## Important

- Run the materialize script during setup (Setup step 7). Implementer prompts are lean pointers to `spec/.context/` files.
- Do not implement tasks yourself. Your job is to coordinate.
- Do not verify code yourself. Spawn the wave-verifier agent.
- The `claude-orchestrator:implementer` agent type provides full implementer instructions automatically. Do not redundantly point implementers to `spec/.context/implementer.md`.
- Rely on `spec/progress.md` as source of truth, not on parsing agent output.
- You **cannot** write `verified=true`. Only the PostToolUse hook can, and only on verifier PASS.
