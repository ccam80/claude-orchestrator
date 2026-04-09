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
        - type: command
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/gate-verifier.sh\""
---

# Implement Hybrid

You are the implementation coordinator. You read specs, plan all batches upfront, write the state file once, then spawn agents. A combination of runtime hooks and in-band scripts run by the subagents themselves manage state transitions. You only touch the state file after setup under the dead-subagent fallback described below.

## Architecture

```
implement-orchestrated (3 levels):        implement-hybrid (2 levels):
  coordinator                               coordinator (you)
    └─ orchestrator  ← ELIMINATED             └─ implementers (direct)
         └─ implementers                      └─ wave-verifier
    └─ reviewer
```

## Verification Gate

Two PreToolUse hooks gate spawns at the Claude Code runtime level; five in-band scripts are invoked either by the subagents themselves or by you (the coordinator) to record state transitions:

| Script | Invoked by | When | Action |
|--------|-----------|------|--------|
| `gate-implementer.sh` | Claude Code (PreToolUse on Agent, skill frontmatter) | Before each Agent tool call | Filters on `subagent_type=implementer`; checks spawn conditions, increments `spawned` on allow; exit 2 with stderr reason on block |
| `gate-verifier.sh` | Claude Code (PreToolUse on Agent, skill frontmatter) | Before each Agent tool call | Filters on `subagent_type=wave-verifier`; blocks if nothing to verify or the batch is already fully verified |
| `complete-implementer.sh` | **implementer agent itself** | As the implementer's final bash call before returning normally | Increments `completed` on the current batch |
| `stop-for-clarification.sh` | **implementer agent itself** | As the final bash call when the implementer is stopping because the spec is ambiguous (alternative to `complete-implementer.sh`) | Increments `stops_for_clarification` on the current batch — opens a retry slot without marking work as completed |
| `mark-verified.sh` | **wave-verifier agent itself** | As the verifier's final bash call, with a JSON verdict map as arg | Updates `group_status` per task_group, increments `verifications_passed` / `verifications_failed`; rejects any entry for a task_group that is already `passed` |
| `mark-dead-implementer.sh` | **you (the coordinator)** | When you have positive evidence an implementer subagent died without running `complete-implementer.sh` | Increments `dead_implementers` on the current batch — opens a retry slot |
| `mark-dead-verifier.sh` | **you (the coordinator)** | When you have positive evidence a wave-verifier died without running `mark-verified.sh` | Increments `dead_verifiers` for observability; no gate impact — just re-spawn the verifier afterwards |

**Why in-band recording?** Claude Code's `SubagentStop` hooks (whether registered on the skill or on the agent's own frontmatter as `Stop`) are not reliably invoked for background subagents — this is a known issue. `PostToolUse:Agent` fires when the `Agent` tool *returns*, which for `run_in_background: true` is at spawn time, long before the subagent finishes. The only reliable mechanism is to have the subagent invoke the recording script itself as its last action before returning. The implementer and wave-verifier agents' workflows make this mandatory.

**You do not write counter fields in the state file after setup.** Normal completion, clarification, and verdict updates are all written by scripts the subagents invoke themselves. The only time you, the coordinator, touch counters is by invoking `mark-dead-implementer.sh` or `mark-dead-verifier.sh` — never by editing the state file directly.

### Dead-Subagent Fallback

An in-band recording script is only as reliable as the subagent running it. If a subagent dies or hangs before invoking its script, its counter never increments and the batch stalls. Recovery protocol when a spawn appears stuck:

1. Look up the subagent's `agentId` from the `TaskOutput` retrieval or the spawn response.
2. Inspect the subagent's process / output file to determine whether it is actually still running, or dead with no further output. If `TaskOutput` returned a `completed` status but the counter didn't move, the agent finished without running its recording script.
3. **Only when you have positive evidence the subagent is dead** (`TaskOutput` returned completed/failed, or the process is no longer present), invoke the matching recovery script from the project root:
   - For a dead implementer: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark-dead-implementer.sh"` — increments `dead_implementers`, opens a retry slot. Do not manually edit `batch.completed`: a dead implementer did not complete anything, and counting it as completed would cause the wave-verifier to verify work that does not exist.
   - For a dead wave-verifier: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark-dead-verifier.sh"`, then spawn a replacement verifier. A dead verifier leaves `verifications_passed` / `verifications_failed` / `group_status` untouched, so the gate will allow the replacement automatically without any counter surgery.
4. Log the recovery in `spec/progress.md` under a **Recovery events** heading with timestamp, batch id, which script you invoked, and why (e.g. "TaskOutput returned completed for agent X but counters unchanged after 30s").

Never use this fallback speculatively. A live subagent whose counter simply hasn't updated yet is not dead — wait for `TaskOutput(block=true)` to return before considering intervention.

### Clarification Stops

An implementer that hits a blocking spec ambiguity is expected to take the "Clarification Exit" path described in `agents/implementer.md`: release its locks, append a `CLARIFICATION NEEDED` entry to `spec/progress.md`, and call `stop-for-clarification.sh` as its final bash call. When you read `spec/progress.md` after processing implementer results (step 2 of "For Each Batch"), look for any `CLARIFICATION NEEDED` entries — those are questions the user must answer before the batch can progress. Surface the entry verbatim to the user, wait for the answer, update the phase spec file with the clarified wording, and then respawn a fresh implementer for the affected task_group. The spawn gate allows the respawn because `stops_for_clarification` opened a retry slot on the current batch.

### Counter + Per-Group-Status State

The state file `spec/.hybrid-state.json` combines counters with per-task_group status. The counters drive the spawn cap; the per-group status is the definitive "batch done" signal.

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
      "verifications_failed": 0,
      "stops_for_clarification": 0,
      "dead_implementers": 0,
      "dead_verifiers": 0,
      "group_status": {
        "1.1": "pending",
        "1.2": "pending",
        "1.3": "pending"
      }
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**Fields you write (once, at setup):** `id`, `task_groups`, `tasks`, all seven counters initialized to 0, and `group_status` with every task_group set to `"pending"`.

**Fields written after setup (do not edit them yourself):**
- `spawned` — written by `gate-implementer.sh` (PreToolUse hook, automatic).
- `completed` — written by `complete-implementer.sh`, invoked by the implementer agent as its final bash call on a normal finish.
- `stops_for_clarification` — written by `stop-for-clarification.sh`, invoked by the implementer agent as its final bash call when it takes the clarification exit path instead of finishing the task.
- `verifications_passed` / `verifications_failed` / `group_status` — written by `mark-verified.sh`, invoked by the wave-verifier agent as its final bash call with a JSON verdict map.
- `dead_implementers` / `dead_verifiers` — written by `mark-dead-implementer.sh` / `mark-dead-verifier.sh`, which you (the coordinator) invoke under the dead-subagent fallback.
- `last_updated` — written by whichever of the above runs most recently.

Each **task_group** is one implementer's assignment — the tasks that one agent will work on. The `task_groups` array has one entry per implementer you plan to spawn. The `tasks` array is parallel — `tasks[i]` lists the spec task IDs for `task_groups[i]`. `group_status[task_group_id]` tracks whether that group is currently `"pending"`, `"failed"`, or `"passed"`.

`verifications_passed` and `verifications_failed` are cumulative historical counts used by the spawn cap formula — a group that was FAILED and then PASSED on retry shows `verifications_passed=1, verifications_failed=1` and `group_status[group] == "passed"`. The historical `verifications_failed` stays at 1 because it opened a retry slot that was consumed; the current status is the authoritative "is this group done" signal.

### Spawn Conditions

**Implementer allowed when ALL true:**
1. `spawned < len(task_groups) + verifications_failed + stops_for_clarification + dead_implementers` — total slot cap (initial slots, plus one retry slot per historical failure, clarification stop, or dead implementer)
2. `verifications_passed + verifications_failed >= completed` — all completed work has been reviewed (clarification stops and dead implementers do not contribute to `completed`, so they do not block this check)

**Verifier allowed when ALL true:**
1. At least one task_group in `group_status` is not yet `"passed"` — the batch is not fully verified
2. `completed > verifications_passed + verifications_failed` — unreviewed completed work exists

**Batch is fully verified when** every task_group in `group_status` equals `"passed"`. This replaces the old `verifications_passed >= len(task_groups)` check, which could silently accept over-counted verdicts when retry verifiers padded the verdict string with PASS tokens for already-passed groups.

### If a Hook Blocks You

If you see a `BLOCKED:` message:

- **"spawn_cap"** — all implementer slots used. Spawn a wave-verifier to review completed work. Retry slots are added by failed verifications, clarification stops (`stops_for_clarification`), and dead implementers (`dead_implementers`).
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
6. Materialize shared context files:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" hybrid "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
7. Initialize lock directories:
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
      "verifications_failed": 0,
      "stops_for_clarification": 0,
      "dead_implementers": 0,
      "dead_verifiers": 0,
      "group_status": {
        "1.1": "pending",
        "1.2": "pending"
      }
    },
    {
      "id": "batch-2",
      "task_groups": ["2.1"],
      "tasks": [["T2.1a", "T2.1b"]],
      "spawned": 0,
      "completed": 0,
      "verifications_passed": 0,
      "verifications_failed": 0,
      "stops_for_clarification": 0,
      "dead_implementers": 0,
      "dead_verifiers": 0,
      "group_status": {
        "2.1": "pending"
      }
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**After this write, do not modify the state file again except via the recovery scripts.** Normal counter updates happen through in-band scripts the subagents invoke themselves; `dead_implementers` / `dead_verifiers` are written by the matching recovery scripts when you invoke them under the dead-subagent fallback.

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

Execute batches in order. The hooks enforce: you cannot start batch N+1 until every task_group in batch N has `group_status == "passed"`.

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

After spawning all implementers in one message, call `TaskOutput(task_id, block=true)` for each in a follow-up message. Each implementer invokes `complete-implementer.sh` as its own final bash call on a normal finish, which increments `completed` on the current batch; an implementer that hit a spec ambiguity will instead invoke `stop-for-clarification.sh`, which increments `stops_for_clarification` without touching `completed`.

When `TaskOutput` returns with `status: completed` for every implementer, re-read `spec/.hybrid-state.json`:
- `completed` should equal the number of implementers that finished normally.
- `stops_for_clarification` should equal the number of implementers that took the clarification exit.
- If an implementer returned a completed `TaskOutput` status but neither counter advanced, the agent finished without running either recording script — apply the dead-subagent fallback and call `mark-dead-implementer.sh`.

#### 2. Process Results

After all implementer Tasks return:
1. Read `spec/progress.md` for updated status — this is the source of truth for file lists and per-task outcomes.
2. Look for any `CLARIFICATION NEEDED` entries in `spec/progress.md`. Each one is a blocker: surface the entry to the user verbatim, wait for the answer, edit the phase spec file to bake in the clarified wording, then respawn a fresh implementer for the affected task_group (the `stops_for_clarification` counter will have opened a retry slot for you).
3. If tasks remain incomplete for reasons other than clarification (e.g. a partial finish noted in `spec/progress.md`), you may spawn more implementers; the hooks will allow this only if retry slots are available from failed verifications, clarification stops, or dead implementers.
4. Commit completed work:
   ```bash
   git add -A
   git commit -m "Batch {batch_id} implementation complete"
   ```
5. Clean locks:
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

Before assembling the prompt, read `spec/.hybrid-state.json` and compute the list of **unreviewed task_groups** for the active batch — every task_group whose `group_status` is either `"pending"` (never verified) or `"failed"` (verified FAIL and subsequently retried). This is the exact list the verifier must verify in this run; already-`"passed"` groups must not be re-verified, and `mark-verified.sh` will reject them if the verifier tries.

Use this prompt template:

```markdown
# Wave Verification Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Batch: {batch_id}
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Unreviewed task_groups to verify in this run**: {unreviewed_task_group_list}
- **Tasks per group**: {tasks_per_group restricted to unreviewed groups}

Verify ONLY the task_groups listed above. Do NOT emit a verdict for any task_group that is not in this list — those are already passed and re-verifying them is a counter-corruption bug the state file will reject.

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

The wave-verifier invokes `mark-verified.sh '<json-verdict-map>'` as its own final bash call, passing a JSON object whose keys are the unreviewed task_group IDs it verified and whose values are `PASS` or `FAIL` (e.g. `'{"0.1.a":"PASS","0.1.c":"FAIL"}'`). That script updates `group_status` per task_group and increments `verifications_passed` / `verifications_failed`.

After `TaskOutput` returns, re-read `spec/.hybrid-state.json` to confirm `group_status` advanced for the expected task_groups. If it did not (verifier died before running its recording script), invoke `mark-dead-verifier.sh` and spawn a replacement verifier with the same unreviewed task_group list — no other counter surgery is needed, because a dead verifier leaves the verification counters and `group_status` untouched. Cross-check the verifier's returned report `## Verdict` JSON map against `group_status` — if they disagree, trust the state file and investigate the discrepancy before proceeding.

#### 4. Handle Verification Failure

If the verifier reported failures:

1. Read the verifier's output — specifically the **Failure Summary** section listing every reason for failure per task group.

2. Spawn fix implementers for the failed groups. The gate allows this because `verifications_failed` increased the spawn cap. Use the implementer prompt template with the fix tasks and failure reasons.

3. Wait for fix agents, then spawn the verifier again to re-verify.

4. If still failing after 2 fix rounds → report to user. Ask how to proceed.

#### 5. Next Batch

After every task_group in the batch has `group_status == "passed"`, proceed to the next batch (back to step 1). The hooks will now target the next incomplete batch.

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
- **State file enables recovery.** If context compresses, re-read `spec/.hybrid-state.json`. The combination of counters and `group_status` tells you exactly where you are on the active batch (first batch whose `group_status` has any entry that is not `"passed"`):
  - `spawned < len(task_groups) + verifications_failed + stops_for_clarification + dead_implementers` and at least one group is still `"pending"` → room to spawn more implementers for first-pass work or retries.
  - `completed + stops_for_clarification + dead_implementers < spawned` → still waiting for implementers to finish (normally, via clarification, or to be declared dead).
  - `completed > verifications_passed + verifications_failed` → unreviewed completed work exists, spawn a verifier.
  - Some task_groups have `group_status == "failed"` and the last verifier run is done → spawn retry implementers for those specific groups.
  - Every task_group has `group_status == "passed"` → batch done, move to the next one.

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

- Plan all batches and write the state file ONCE during setup. After that, never edit the state file by hand — all updates happen through the in-band scripts and the dead-subagent recovery scripts.
- Do not implement tasks yourself. Your job is to coordinate.
- Do not verify code yourself. Spawn the wave-verifier agent.
- The `claude-orchestrator:implementer` agent type loads its instructions automatically.
- Rely on `spec/progress.md` as source of truth, not on parsing agent output.
- Ownership of state fields:
  - `spawned` — written by the PreToolUse `gate-implementer.sh` hook.
  - `completed` — written by `complete-implementer.sh`, invoked by the implementer on a normal finish.
  - `stops_for_clarification` — written by `stop-for-clarification.sh`, invoked by the implementer on a clarification exit.
  - `verifications_passed` / `verifications_failed` / `group_status` — written by `mark-verified.sh`, invoked by the wave-verifier.
  - `dead_implementers` / `dead_verifiers` — written by `mark-dead-implementer.sh` / `mark-dead-verifier.sh`, which you invoke under the dead-subagent fallback described in the "Dead-Subagent Fallback" section.
