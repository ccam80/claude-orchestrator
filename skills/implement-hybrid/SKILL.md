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
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/gate-implementer.sh\""
  PostToolUse:
    - matcher: "Agent"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/complete-implementer.sh\""
        - type: command
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/mark-verified.sh\""
---

# Implement Hybrid

You are the implementation coordinator. You read specs, plan all batches upfront, write the state file once, then spawn agents. Hooks manage all state transitions — you never touch the state file after setup.

## Architecture

```
implement-orchestrated (3 levels):        implement-hybrid (2 levels):
  coordinator                               coordinator (you)
    └─ orchestrator  ← ELIMINATED             └─ implementers (direct)
         └─ implementers                      └─ wave-verifier
    └─ reviewer
```

## Hook-Enforced Verification Gate

Four hooks registered via frontmatter manage all state transitions:

| Hook | Trigger | Action |
|------|---------|--------|
| `gate-implementer.sh` | PreToolUse on implementer | Checks spawn conditions, increments `spawned` on allow |
| `complete-implementer.sh` | PostToolUse on implementer | Increments `completed` |
| `gate-verifier.sh` | PreToolUse on verifier | Blocks if nothing to verify or batch already done |
| `mark-verified.sh` | PostToolUse on verifier | Parses per-task-group verdicts, increments `passed`/`failed` |

**You do not write to the state file after setup.** The hooks own all counter fields. Your only job after setup is to spawn agents and read their output.

### Counter-Based State

The state file `spec/.hybrid-state.json` uses counters, not status fields:

```json
{
  "batches": [
    {
      "id": "batch-1",
      "task_groups": ["1.1", "1.2", "1.3"],
      "tasks": [["T2.1", "T2.3"], ["T1.2"], ["T3.3", "T2.2"]],
      "spawned": 0,
      "completed": 0,
      "verifications_passed": 0,
      "verifications_failed": 0
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**Fields you write (once, at setup):** `id`, `task_groups`, `tasks`, and the four counters initialized to 0.

**Fields hooks write:** `spawned`, `completed`, `verifications_passed`, `verifications_failed`, `last_updated`.

Each **task_group** is one implementer's assignment — the tasks that one agent will work on. The `task_groups` array has one entry per implementer you plan to spawn. The `tasks` array is parallel — `tasks[i]` lists the spec task IDs for `task_groups[i]`.

### Spawn Conditions

**Implementer allowed when ALL true:**
1. `spawned < len(task_groups) + verifications_failed` — haven't exceeded initial slots + retry slots
2. `verifications_passed + verifications_failed >= completed` — all completed work has been reviewed

**Verifier allowed when ALL true:**
1. `verifications_passed < len(task_groups)` — batch not fully verified yet
2. `completed > verifications_passed + verifications_failed` — unreviewed completed work exists

### If a Hook Blocks You

If you see a `BLOCKED:` message:

- **"spawn_cap"** — all implementer slots used. Spawn a wave-verifier to review completed work. Failed verifications add retry slots.
- **"unreviewed_work"** — completed implementations haven't been verified. Spawn a wave-verifier.
- **"nothing_to_verify"** — no unreviewed work. Wait for implementers to complete, or check if the batch is already done.
- **"all_batches_verified"** — all batches are done. Proceed to cleanup.

Do NOT modify the state file to work around a block. The hooks enforce correctness.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` — phase dependency graph, wave structure, task complexities. Identify which waves can run in parallel.
3. If `$ARGUMENTS` specifies a phase, limit execution to that phase. Otherwise execute all incomplete phases in dependency order.
4. Check for recovery state:
   - If `spec/.hybrid-state.json` exists, read it — resume from where counters left off.
   - Otherwise read `spec/progress.md` to determine what's already complete.
5. Read the phase spec file for the **first incomplete phase only**.
6. Read the project's `CLAUDE.md` for project-specific rules.
7. Materialize shared context files:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" hybrid "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
8. Initialize lock directories:
   ```bash
   mkdir -p "spec/.locks/tasks" "spec/.locks/files"
   ```

## Plan All Batches (Step 1 — Write State Once)

Before spawning anything, plan ALL batches for the current phase and write the state file. This is the **only time** you write to `spec/.hybrid-state.json`.

From the phase spec and `spec/plan.md`:
- Identify which waves can run in parallel (the spec marks these explicitly).
- Group parallel waves into a single **batch**. Sequential waves each get their own batch.
- For each batch, determine the task_groups: one entry per implementer you will spawn. Assign tasks to groups based on complexity and parallelism (`min(tasks, 4)` groups per batch).

Write the complete state file:

```json
{
  "batches": [
    {
      "id": "batch-1",
      "task_groups": ["1.1", "1.2"],
      "tasks": [["T1.1a", "T1.1b"], ["T1.2a"]],
      "spawned": 0,
      "completed": 0,
      "verifications_passed": 0,
      "verifications_failed": 0
    },
    {
      "id": "batch-2",
      "task_groups": ["2.1"],
      "tasks": [["T2.1a", "T2.1b"]],
      "spawned": 0,
      "completed": 0,
      "verifications_passed": 0,
      "verifications_failed": 0
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**After this write, do not modify the state file again.** All counter updates happen via hooks.

## Test Baseline

Before spawning the first batch of implementers, capture the pre-existing test state. Spawn a lightweight background Task:

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

Wait for the baseline Task to complete via `TaskOutput(task_id, block=true)`.

## Batch Execution

Execute batches in order. The hooks enforce: you cannot start batch N+1 until batch N is fully verified (`verifications_passed == len(task_groups)`).

### For Each Batch

#### 1. Spawn Implementers

Spawn one implementer per task_group, ALL **in a single message** as background Tasks:

- **subagent_type**: `claude-orchestrator:implementer`
- **model**: S (Small) → `haiku`, M (Medium) or L (Large) → `sonnet`
- **run_in_background**: `true`
- **description**: short label, e.g. `"Implement {task_group_id}"`

The PreToolUse hook increments `spawned` for each allowed spawn and blocks if the cap is reached.

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
{remaining tasks in this task_group}

## Context Files
Read these files before doing anything else:
- `spec/.context/rules.md` — implementation rules (non-negotiable, includes shell safety)
- `spec/.context/lock-protocol.md` — lock coordination protocol
- `spec/phase-{n}-{name}.md` — find your task by ID for full specification
- `CLAUDE.md` — project-specific rules and conventions
- `spec/test-baseline.md` — pre-existing test failures (check before investigating any test failure)
```

After spawning all implementers in one message, call `TaskOutput(task_id, block=true)` for each in a follow-up message. The PostToolUse hook increments `completed` as each returns.

#### 2. Process Results

After all implementer Tasks return:
1. Read `spec/progress.md` for updated status — this is the source of truth.
2. If tasks remain incomplete, you may spawn more implementers (the hooks will allow this only if retry slots are available from failed verifications).
3. Commit completed work:
   ```bash
   git add -A
   git commit -m "Batch {batch_id} implementation complete"
   ```
4. Clean locks:
   ```bash
   rm -rf "spec/.locks/tasks/"* "spec/.locks/files/"* 2>/dev/null
   ```

#### 3. Spawn Wave Verifier

Spawn the wave-verifier as a background Task:

- **subagent_type**: `claude-orchestrator:wave-verifier`
- **model**: `sonnet`
- **run_in_background**: `true`
- **description**: `"Verify batch {batch_id}"`

The PreToolUse hook checks that unreviewed completed work exists before allowing the spawn.

Use this prompt template:

```markdown
# Wave Verification Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Batch: {batch_id}
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Task groups**: {task_group_list}
- **Tasks per group**: {tasks_per_group}

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

The PostToolUse hook parses the verifier's `## Verdict:` line (one verdict per task group, space-separated) and increments `verifications_passed` and `verifications_failed`.

You will see a hook context message:
- `"Batch fully verified (N/N passed)"` — proceed to next batch.
- `"N passed, M failed"` — read the verifier's Failure Summary and spawn fix implementers.
- `"WARNING"` — verdict unparseable, report to user.

#### 4. Handle Verification Failure

If the verifier reported failures:

1. Read the verifier's output — specifically the **Failure Summary** section listing every reason for failure per task group.

2. Spawn fix implementers for the failed groups. The gate allows this because `verifications_failed` increased the spawn cap. Use the implementer prompt template with the fix tasks and failure reasons.

3. Wait for fix agents, then spawn the verifier again to re-verify.

4. If still failing after 2 fix rounds → report to user. Ask how to proceed.

#### 5. Next Batch

After the batch is fully verified (`verifications_passed == len(task_groups)`), proceed to the next batch (back to step 1). The hooks will now target the next incomplete batch.

### Phase Completion

After all batches in a phase are verified:

1. Append phase summary to `spec/progress.md`:
   ```markdown
   ---
   ## Phase {n} Complete
   - **Batches**: {count}
   - **All verified**: yes
   ```

2. Continue to the next phase — read its spec, plan batches, write state entries, execute.

### After All Phases

1. Run verification measures from `spec/plan.md` (test commands, acceptance criteria).
2. Report final status: phases/batches/tasks completed, verification outcomes, test results.
3. Clean up:
   ```bash
   rm -f "spec/.hybrid-state.json"
   rm -rf "spec/.locks/"
   ```

## Context Conservation (Critical)

You are a long-running coordinator. Protect your context aggressively:

- **ALWAYS `run_in_background: true`** on Task calls.
- **Use `TaskOutput(block=true)` only.** Never poll.
- **Spawn-then-wait**: spawn multiple background Tasks in one message, then `TaskOutput` each.
- **Never read full git diffs.** Use `git diff --shortstat` if needed.
- **Read phase spec files once per phase**, not per batch.
- **State file enables recovery.** If context compresses, re-read `spec/.hybrid-state.json`. The counters tell you exactly where you are:
  - `spawned < len(task_groups)` → still spawning implementers for this batch.
  - `spawned == len(task_groups)` and `completed < spawned` → waiting for implementers.
  - `completed > verifications_passed + verifications_failed` → need to spawn verifier.
  - `verifications_passed == len(task_groups)` → batch done, move to next.

## Error Handling

- If an implementer Task fails (error return), report to user and ask how to proceed.
- If progress.md shows persistent failures across rounds, surface the details.
- Never silently skip failed tasks — always report and get user direction.
- After `TaskOutput` returns, verify `spec/progress.md` was updated. If no new entries, the implementer failed internally — report to the user.
- After a verifier's `TaskOutput` returns, check the hook's context message for pass/fail counts.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths, never backslashes.
- **Use `/dev/null`**, never `NUL`.
- **Use Unix commands** (`ls`, `rm`, `mkdir`), never Windows commands.

## Important

- Plan all batches and write the state file ONCE during setup. Do not modify it after.
- Do not implement tasks yourself. Your job is to coordinate.
- Do not verify code yourself. Spawn the wave-verifier agent.
- The `claude-orchestrator:implementer` agent type loads its instructions automatically.
- Rely on `spec/progress.md` as source of truth, not on parsing agent output.
- The hooks manage all counters. You cannot and should not write counter values.
