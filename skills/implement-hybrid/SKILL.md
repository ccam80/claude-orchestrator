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
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/gate-user-ack.sh\""
---

# Implement Hybrid

You are the implementation coordinator. You read specs, plan all batches upfront, write the state file once, then spawn agents. A combination of runtime hooks and in-band scripts run by the subagents themselves manage state transitions. You only touch the state file after setup under the dead-subagent fallback described below.

## Architecture

```
coordinator (you)
  └─ implementers (direct)
  └─ wave-verifier
```

## Verification Gate

Two PreToolUse hooks gate spawns at the Claude Code runtime level; five in-band scripts are invoked either by the subagents themselves or by you (the coordinator) to record state transitions:

| Script | Invoked by | When | Action |
|--------|-----------|------|--------|
| `gate-implementer.sh` | Claude Code (PreToolUse on Agent, skill frontmatter) | Before each Agent tool call | Filters on `subagent_type=implementer`; checks spawn conditions, increments `spawned` on allow; exit 2 with stderr reason on block |
| `gate-verifier.sh` | Claude Code (PreToolUse on Agent, skill frontmatter) | Before each Agent tool call | Filters on `subagent_type=wave-verifier`; blocks if nothing to verify or the batch is already fully verified |
| `gate-user-ack.sh` | Claude Code (PreToolUse on Bash, skill frontmatter) | Before any Bash call | Blocks any Claude-initiated invocation of `ack-user-gate.sh` — that script is USER-ONLY and must be run by the user in their own terminal |
| `complete-implementer.sh` | **implementer agent itself** | As the implementer's final bash call before returning normally | Increments `completed` on the current batch |
| `stop-for-clarification.sh` | **implementer agent itself** | As the final bash call when the implementer is stopping because the spec is ambiguous (alternative to `complete-implementer.sh`) | Increments `stops_for_clarification` on the current batch — opens a retry slot without marking work as completed |
| `mark-verified.sh` | **wave-verifier agent itself** | As the verifier's final bash call, with a JSON verdict map as arg | Updates `group_status` per task_group, increments `verifications_passed` / `verifications_failed`; rejects any entry for a task_group that is already `passed`, and rejects PASS for any group with unacked `user_required_tasks` |
| `ack-user-gate.sh` | **the user, in their own terminal** (NOT Claude) | When the user has performed a real-world user-required action | Writes `user_acks[task_id]` on the batch whose `user_required_tasks` lists the task. Agent-initiated calls are blocked by `gate-user-ack.sh` |
| `mark-dead-implementer.sh` | **you (the coordinator)** | When you have positive evidence an implementer subagent died without running `complete-implementer.sh` | Increments `dead_implementers` on the current batch — opens a retry slot |
| `mark-dead-verifier.sh` | **you (the coordinator)** | When you have positive evidence a wave-verifier died without running `mark-verified.sh` | Increments `dead_verifiers` for observability; no gate impact — just re-spawn the verifier afterwards |
| `i-fixed-it.sh` | **you (the coordinator)** — escape hatch | When you have made a trivial in-place fix and want to re-run the verifier without spawning another implementer. Prefer spawning a fix-implementer in almost all cases. | "Phantom implementer" record: increments BOTH `spawned` and `completed` by 1, so the verifier gate unlocks and a retry slot is consumed. Requires a `failed` group to exist on the active batch. |
| `reopen-implementer-slot.sh` | **you (the coordinator)** — escape hatch | When an implementer returned "complete" but you have concluded the work wasn't actually done, and you want to skip running a verifier just to hear it say FAIL | Erases the phantom completion: decrements BOTH `completed` and `spawned` by 1. Requires a group_id and a reason argument. |

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

### Coordinator Escape Hatches (use sparingly)

Two scripts exist for state surgery the coordinator does directly, without spawning a subagent. Both are explicitly low-advertised: the preferred path for a failed verification is still to spawn a fix-implementer, and the preferred path for catching a bogus completion is still to let the verifier catch it. Reach for these only when the alternative is wasting a subagent cycle for no gain.

**`i-fixed-it.sh`** — you have made a trivial in-place fix (typo, import reorder, lint nit) to code produced by a prior implementer, and you want the wave-verifier to re-audit the batch without spawning another implementer. The script takes a one-line description and records a "phantom implementer" by incrementing BOTH `spawned` and `completed` on the active batch. Verifier gate unlocks; spawn-cap stays tight (a retry slot is consumed, matching what a real implementer would have cost).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/i-fixed-it.sh" "Removed stray trailing comma in src/foo.ts L12"
```

Preconditions the script enforces:
- an active batch exists (not fully passed)
- at least one group in the active batch has `group_status == "failed"` — you can only use this to recover from a FAIL, not to skip first-pass implementation
- an implementer spawn slot is currently open (`spawned < cap`)

**`reopen-implementer-slot.sh`** — an implementer returned "complete" (incrementing `completed` via its own in-band script) but you have positive evidence the work wasn't actually done, and you want to skip spawning a verifier just to hear it say FAIL. The script takes the group_id and a reason, and decrements BOTH `completed` and `spawned`. Net effect: the phantom completion is erased. Verifier gate closes; implementer gate opens.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reopen-implementer-slot.sh" "1.2" "Returned 'complete' without creating any of the required files"
```

Preconditions the script enforces:
- an active batch exists
- the group_id is in the active batch and is not already `passed`
- `completed > verifications_passed + verifications_failed` (there is an unreviewed completion to erase); if the bogus completion has already been verified, use the normal fix-implementer path against the `failed` retry slot instead
- `spawned > 0`

Both scripts append an entry to `batches[].recovery_log` with the timestamp, script name, and your description / reason. This log is purely for audit — no gate reads it — but it is the only durable record of coordinator interventions, so be precise in the string you pass.

### Clarification Stops

An implementer that hits a blocking spec ambiguity is expected to take the "Clarification Exit" path described in `agents/implementer.md`: release its locks, append a `CLARIFICATION NEEDED` entry to `spec/progress.md`, and call `stop-for-clarification.sh` as its final bash call. When you read `spec/progress.md` after processing implementer results (step 2 of "For Each Batch"), look for any `CLARIFICATION NEEDED` entries — those are questions the user must answer before the batch can progress. Surface the entry verbatim to the user, wait for the answer, update the phase spec file with the clarified wording, and then respawn a fresh implementer for the affected task_group. The spawn gate allows the respawn because `stops_for_clarification` opened a retry slot on the current batch.

### Counter + Per-Group-Status State

The state file `spec/.hybrid-state.json` combines counters with per-task_group status. The counters drive the spawn cap; the per-group status is the definitive "batch done" signal.

```json
{
  "batches": [
    {
      "id": "batch-1",
      "phase": 1,
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
      },
      "user_required_tasks": {
        "1.1": [],
        "1.2": ["T1.2"],
        "1.3": []
      },
      "user_acks": {}
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**Fields you write (once, at setup, for every batch of every phase in scope):** `id`, `phase`, `task_groups`, `tasks`, all seven counters initialized to 0, `group_status` with every task_group set to `"pending"`, `user_required_tasks` mapping each task_group to the list of task_ids in that group whose spec explicitly requires a user action (empty list if none), and `user_acks` initialized to `{}`.

**Fields written after setup (do not edit them yourself):**
- `spawned` — written by `gate-implementer.sh` (PreToolUse hook, automatic), and adjusted by `i-fixed-it.sh` / `reopen-implementer-slot.sh` under the escape-hatch paths.
- `completed` — written by `complete-implementer.sh`, invoked by the implementer agent as its final bash call on a normal finish, and adjusted by `i-fixed-it.sh` / `reopen-implementer-slot.sh`.
- `stops_for_clarification` — written by `stop-for-clarification.sh`, invoked by the implementer agent as its final bash call when it takes the clarification exit path instead of finishing the task.
- `verifications_passed` / `verifications_failed` / `group_status` — written by `mark-verified.sh`, invoked by the wave-verifier agent as its final bash call with a JSON verdict map.
- `dead_implementers` / `dead_verifiers` — written by `mark-dead-implementer.sh` / `mark-dead-verifier.sh`, which you (the coordinator) invoke under the dead-subagent fallback.
- `user_acks` — written ONLY by the user running `ack-user-gate.sh` in their own terminal. Never write this field from any Claude-driven path; the PreToolUse `gate-user-ack.sh` hook blocks agent-initiated invocations.
- `recovery_log` — appended by `i-fixed-it.sh` / `reopen-implementer-slot.sh` as an audit trail of coordinator interventions.
- `last_updated` — written by whichever of the above runs most recently.

Each **task_group** is one implementer's assignment — the tasks that one agent will work on. The `task_groups` array has one entry per implementer you plan to spawn. The `tasks` array is parallel — `tasks[i]` lists the spec task IDs for `task_groups[i]`. `group_status[task_group_id]` tracks whether that group is currently `"pending"`, `"failed"`, or `"passed"`.

`verifications_passed` and `verifications_failed` are cumulative historical counts used by the spawn cap formula — a group that was FAILED and then PASSED on retry shows `verifications_passed=1, verifications_failed=1` and `group_status[group] == "passed"`. The historical `verifications_failed` stays at 1 because it opened a retry slot that was consumed; the current status is the authoritative "is this group done" signal.

### Spawn Conditions

**Implementer allowed when:**
- `spawned < len(task_groups) + verifications_failed + stops_for_clarification + dead_implementers` — total slot cap (initial slots, plus one retry slot per historical failure, clarification stop, or dead implementer)

There is no "must verify before more spawns" gate. While first-pass implementers are running, you may freely mark dead agents and spawn replacements until every task_group has a finished implementer. Verification happens once at the end of the batch, after all task_groups have at least one completed implementer.

**Verifier allowed when ALL true:**
1. At least one task_group in `group_status` is not yet `"passed"` — the batch is not fully verified
2. `completed > verifications_passed + verifications_failed` — unreviewed completed work exists

**Batch is fully verified when** every task_group in `group_status` equals `"passed"`. This replaces the old `verifications_passed >= len(task_groups)` check, which could silently accept over-counted verdicts when retry verifiers padded the verdict string with PASS tokens for already-passed groups.

### Verifier Fan-Out (one verifier per 4 task_groups)

A single wave-verifier verifying many task_groups at once becomes overloaded — it has to read many spec files, audit many file lists, and produce many verdicts in a single context. Split the verification across multiple verifiers when the unreviewed task_group list is long.

Rule: spawn `ceil(unreviewed_task_groups / 4)` verifiers in parallel, each assigned a disjoint subset of up to 4 task_groups from the unreviewed list. All verifiers run on the same batch concurrently; each calls `mark-verified.sh` independently with a verdict map covering only its assigned task_groups. The script accepts concurrent verdicts as long as no two verifiers were assigned the same task_group (and they cannot be — you produce disjoint subsets).

Examples:
- 1–4 unreviewed task_groups → 1 verifier
- 5–8 unreviewed task_groups → 2 verifiers (e.g. 4 and 4, or 4 and the rest)
- 9–12 unreviewed task_groups → 3 verifiers
- and so on

### If a Hook Blocks You

If you see a `BLOCKED:` message:

- **"spawn_cap"** — all implementer slots used. If every task_group already has a finished implementer, spawn wave-verifiers (one per 4 task_groups). Retry slots are added by failed verifications, clarification stops (`stops_for_clarification`), and dead implementers (`dead_implementers`).
- **"nothing_to_verify"** — no unreviewed work. Wait for implementers to complete, or check if the batch is already done.
- **"all_batches_verified"** — all batches are done. Proceed to cleanup.

Do NOT modify the state file to work around a block. The hooks enforce correctness.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/manifest.json` — the job-control artifact. It contains, in execution order, every phase, its waves, the task_groups per wave, each task's complexity, each group's user-required task IDs, the `test_command`, and the final `verification` checks. This is the **only** input you need to plan the run. Do not read `spec/plan.md` (a planning document, not a runtime input) and do not read the phase spec files yourself — those are read by the implementers and verifiers you spawn, not by you. If `spec/manifest.json` is missing, surface it to the user as a planning failure (the phases have not been specced) and stop.
3. If `$ARGUMENTS` specifies a phase, limit execution to that phase's batches. Otherwise execute all incomplete phases in the manifest's order.
4. Check for recovery state:
   - If `spec/.hybrid-state.json` exists, read it — resume from where counters left off.
   - Otherwise read `spec/progress.md` to determine what's already complete.
5. Materialize shared context files:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" hybrid "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
6. Initialize lock directories:
   ```bash
   mkdir -p "spec/.locks/tasks" "spec/.locks/files"
   ```

## Plan All Batches (Step 1 — Write State Once)

Before spawning anything, translate `spec/manifest.json` into the batch plan and write the state file. This is the **only time** you write to `spec/.hybrid-state.json`. The state file is complete after setup: every batch of every phase exists in it from the start. You never add a phase's batches later.

The manifest is the contract — you copy from it, you do not author structure:
- Each **wave** in the manifest becomes one **batch**. The manifest's `phases` array is in execution order and each phase's `waves` array is in execution order — flatten phases → waves into the `batches` array in exactly that order. Number batch ids globally (`batch-1`, `batch-2`, … `batch-N`). Do not collapse multiple waves into one batch and do not split one wave across batches.
- Tag each batch with its phase number via the `phase` field. The phase's spec file path (`spec_file`) and each task's `complexity` stay in the manifest — re-read the manifest for them whenever you assemble a spawn prompt; it is immutable for the duration of the run.
- **Task_groups come from the manifest, not from you.** Each wave's `task_groups` array is the implementer assignment. Copy each `group_id` and its `tasks` verbatim. Do NOT re-cluster tasks, merge groups, split groups, or skip groups — the spec author chose these clusters by file locality, and second-guessing them re-introduces the lock contention they were designed to avoid.
- `user_required_tasks` is already enumerated per group in the manifest. Copy it verbatim into each batch's `user_required_tasks` map — do not re-derive it and do not drop entries. `mark-verified.sh` refuses to PASS any group whose user-required tasks are unacked, and the user can only ack tasks listed here.

If `spec/manifest.json` is missing, has an empty `phases` array, or any wave has an empty `task_groups` array, STOP and surface it to the user as a planning failure. Do not improvise groups yourself.

Write the complete state file in one pass. The example below spans two phases — `batch-1` is a wave of phase 1, `batch-2` is a wave of phase 2 — to show that every phase's batches are present from the start:

```json
{
  "batches": [
    {
      "id": "batch-1",
      "phase": 1,
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
      },
      "user_required_tasks": {
        "1.1": [],
        "1.2": ["T1.2a"]
      },
      "user_acks": {}
    },
    {
      "id": "batch-2",
      "phase": 2,
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
      },
      "user_required_tasks": {
        "2.1": []
      },
      "user_acks": {}
    }
  ],
  "last_updated": "{ISO 8601}"
}
```

**After this write, do not modify the state file again except via the recovery scripts. There is no per-phase write step — all phases are in the file now.** Normal counter updates happen through in-band scripts the subagents invoke themselves; `dead_implementers` / `dead_verifiers` are written by the matching recovery scripts when you invoke them under the dead-subagent fallback.

## Test Baseline

Before spawning the first batch of implementers, capture the pre-existing test state. Spawn a lightweight background Task:

- **subagent_type**: `general-purpose`
- **model**: `haiku`
- **run_in_background**: `true`
- **description**: `"Capture test baseline"`

Use this prompt:

```markdown
# Test Baseline Capture

1. The test command is `{test_command}` (filled in by the coordinator from `spec/manifest.json`).
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

Execute batches in order. The hooks enforce: you cannot start batch N+1 until every task_group in batch N has `group_status == "passed"`. Batches span all phases — `batch.phase` is the batch's phase number; look that phase up in `spec/manifest.json` for its `spec_file`, which the implementer and verifier prompts must reference for that batch.

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
5. Clean locks (between-batch reset — wipes lock contents but keeps `spec/.locks/tasks/` and `spec/.locks/files/` directories in place ready for the next batch):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/clear-locks.sh"
   ```

#### 3. Spawn Wave Verifier(s) — fan out at 1 per 4 task_groups

Wait until every task_group in the batch has a finished implementer (i.e. `completed + stops_for_clarification + dead_implementers == spawned`, with no unresolved clarification stops outstanding). Only then move to verification.

Before assembling prompts, read `spec/.hybrid-state.json` and compute the list of **unreviewed task_groups** for the active batch — every task_group whose `group_status` is either `"pending"` (never verified) or `"failed"` (verified FAIL and subsequently retried). This is the exact list to verify in this round; already-`"passed"` groups must not be re-verified, and `mark-verified.sh` will reject them if any verifier tries.

Split the unreviewed list into **disjoint chunks of up to 4 task_groups each** (`ceil(n / 4)` chunks total). Spawn one wave-verifier per chunk, ALL **in a single message** as background Tasks:

- **subagent_type**: `claude-orchestrator:wave-verifier`
- **model**: `sonnet`
- **run_in_background**: `true`
- **description**: `"Verify batch {batch_id} chunk {i}/{total}"`

Each verifier gets only its assigned chunk in its prompt — never the full unreviewed list. A verifier asked to verify 1–4 task_groups stays focused; one asked to verify 8+ overloads its context, drops findings, and pads verdict maps. The chunk size cap is the entire point of the fan-out.

The PreToolUse hook checks that unreviewed completed work exists before allowing each spawn. Concurrent verifiers on the same batch are fine: each writes only its own task_groups via `mark-verified.sh`, and the script rejects duplicate or already-passed entries server-side.

Use this prompt template (one filled-in copy per verifier):

```markdown
# Wave Verification Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Batch: {batch_id}
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Your assigned chunk (verify ONLY these task_groups)**: {chunk_task_group_list}  ← max 4
- **Tasks per group**: {tasks_per_group restricted to your chunk}
Verify ONLY the task_groups listed above. Other verifiers are running concurrently on other chunks of the same batch. Do NOT emit a verdict for any task_group not in your chunk — duplicates and already-passed entries are rejected server-side and re-verifying is a counter-corruption bug.

## Test Command
{test_command from spec/manifest.json}

## Context Files
Read these files before doing anything else:
- `spec/phase-{n}-{name}.md` — task specifications (find each task by ID)
- `spec/.context/rules.md` — implementation rules to check against
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
- `spec/test-baseline.md` — pre-existing test failures
```

**Wait for every verifier to complete** by calling `TaskOutput(task_id, block=true)` for each verifier you spawned, in a follow-up message.

Each wave-verifier invokes `mark-verified.sh '<json-verdict-map>'` as its own final bash call, passing a JSON object whose keys are ONLY the task_group IDs from its assigned chunk and whose values are `PASS` or `FAIL` (e.g. `'{"0.1.a":"PASS","0.1.c":"FAIL"}'`). That script updates `group_status` per task_group and increments `verifications_passed` / `verifications_failed`. Concurrent verifiers writing disjoint chunks are safe — the script validates each entry before applying any.

After all `TaskOutput` calls return, re-read `spec/.hybrid-state.json` to confirm `group_status` advanced for every task_group across every chunk. For each chunk:
- If its `group_status` entries advanced as expected → proceed.
- If they did not (that verifier died before running its recording script) → invoke `mark-dead-verifier.sh` once per dead verifier and spawn replacements with the same chunk assignment. A dead verifier leaves `verifications_passed` / `verifications_failed` / `group_status` untouched, so the gate will allow the replacement automatically.

Cross-check each verifier's returned report `## Verdict` JSON map against `group_status` — if they disagree, trust the state file and investigate the discrepancy before proceeding.

#### 4. Handle Verification Failure

If any verifier reported failures (consolidate across all chunks):

1. Read every verifier's output — specifically the **Failure Summary** section listing each reason for failure per task group. Aggregate the failed groups across chunks.

2. Spawn fix implementers for the failed groups. The gate allows this because `verifications_failed` increased the spawn cap. Use the implementer prompt template with the fix tasks and failure reasons.

3. Wait for fix agents to finish (using `complete-implementer.sh` / clarification / dead-implementer recovery as needed), then run another verification round. The new unreviewed list is exactly the previously-failed groups — so this round usually fits in one verifier (≤4 groups) but still apply the fan-out rule if it doesn't.

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

2. Continue to the next phase's batches. They are **already in `spec/.hybrid-state.json`** — you wrote them at setup. Do not plan batches or write state entries again; just resume Batch Execution at the first batch whose `group_status` still has a non-`"passed"` entry. Each batch's `phase` field maps to a `spec_file` in `spec/manifest.json` for the spawn prompts.

### After All Phases

1. Run the `verification` checks from `spec/manifest.json` (the final acceptance criteria) and the `test_command`.
2. Report final status: phases/batches/tasks completed, verification outcomes, test results.
3. Clean up (end-of-run — `--purge` removes the entire `spec/.locks/` tree, not just its contents):
   ```bash
   rm -f "spec/.hybrid-state.json"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/clear-locks.sh" --purge
   ```

## Context Conservation (Critical)

You are a long-running coordinator. Protect your context aggressively:

- **ALWAYS `run_in_background: true`** on Task calls.
- **Use `TaskOutput(block=true)` only.** Never poll.
- **Spawn-then-wait**: spawn multiple background Tasks in one message, then `TaskOutput` each.
- **Never read full git diffs.** Use `git diff --shortstat` if needed.
- **Read `spec/manifest.json` once at setup** to plan all batches. It is small and immutable for the run — re-read it freely for static lookups (`spec_file`, `complexity`, `test_command`) without cost concern. Never read `spec/plan.md` or the phase spec files yourself; the agents you spawn read the phase specs.
- **State file enables recovery.** If context compresses, re-read `spec/.hybrid-state.json`. The combination of counters and `group_status` tells you exactly where you are on the active batch (first batch whose `group_status` has any entry that is not `"passed"`):
  - `spawned < len(task_groups) + verifications_failed + stops_for_clarification + dead_implementers` → room to spawn more implementers (first-pass work, dead-agent retries, clarification retries, or fix retries — no verification gate blocks this).
  - `completed + stops_for_clarification + dead_implementers < spawned` → still waiting for implementers to finish (normally, via clarification, or to be declared dead). Mark dead and respawn until the batch fills out.
  - Every task_group has a finished implementer AND `completed > verifications_passed + verifications_failed` → spawn `ceil(unreviewed_groups / 4)` verifiers in parallel, each on a disjoint chunk of up to 4 task_groups.
  - Some task_groups have `group_status == "failed"` and the last verifier run is done → spawn retry implementers for those specific groups, then re-verify them.
  - Every task_group has `group_status == "passed"` → batch done, move to the next one.

## User-Required Task Gate

See `references/rules.md` §**User-Required Tasks** for the full rule set — it applies to every agent. Coordinator-specific responsibilities:

### Spec-time enumeration (your responsibility)

At setup (the "Plan All Batches" step above) populate `user_required_tasks[group]` with every task_id in that group whose spec requires the user. The user cannot ack a task you didn't enumerate; if you miss one, the group will never PASS. This is your most easily-missed obligation — re-read every task's spec specifically for user-required language before writing the state file.

### Flow for a user-required task

1. As soon as you know a batch contains a user-required task, present the ack command to the user via `AskUserQuestion`. Include:
   - The task_id and the exact real-world action the user must perform.
   - The verbatim command:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/ack-user-gate.sh" <task_id> "<one-line evidence>"
     ```
   - Explicit instructions that the user must run it in a **separate terminal** (a `!`-prefixed call inside this session goes through the Bash tool and is blocked).
2. Do not spawn implementers for the user-required task itself — they cannot complete it and would take the Clarification Exit. Implementers for other tasks in the same group proceed normally, but the group cannot PASS until the ack is recorded.
3. Wait for the user to confirm. Re-read `spec/.hybrid-state.json` to confirm `user_acks[<task_id>]` is present with the expected evidence.
4. Only then spawn the wave-verifier. `mark-verified.sh` enforces the gate server-side: it will not record PASS unless every user-required task has an ack entry.

The prohibitions (do not recommend deferral, do not ack on the user's behalf, do not edit `user_acks` directly, do not advance past an unacked gate) are listed in `references/rules.md` §**User-Required Tasks** — they bind you as much as any spawned agent.

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

- Plan all batches for **every phase in scope** and write the state file ONCE during setup. Phases are never added incrementally — the state file contains every batch of every phase from the start. After that write, never edit the state file by hand — all updates happen through the in-band scripts and the dead-subagent recovery scripts.
- Do not implement tasks yourself. Your job is to coordinate.
- Do not verify code yourself. Spawn the wave-verifier agent.
- The `claude-orchestrator:implementer` agent type loads its instructions automatically.
- Rely on `spec/progress.md` as source of truth, not on parsing agent output.
- Ownership of state fields:
  - `spawned` — written by the PreToolUse `gate-implementer.sh` hook; adjusted by `i-fixed-it.sh` / `reopen-implementer-slot.sh` under the escape-hatch paths.
  - `completed` — written by `complete-implementer.sh`, invoked by the implementer on a normal finish; adjusted by `i-fixed-it.sh` / `reopen-implementer-slot.sh`.
  - `stops_for_clarification` — written by `stop-for-clarification.sh`, invoked by the implementer on a clarification exit.
  - `verifications_passed` / `verifications_failed` / `group_status` — written by `mark-verified.sh`, invoked by the wave-verifier.
  - `dead_implementers` / `dead_verifiers` — written by `mark-dead-implementer.sh` / `mark-dead-verifier.sh`, which you invoke under the dead-subagent fallback described in the "Dead-Subagent Fallback" section.
  - `user_required_tasks` — written ONCE by you at setup, enumerating the user-required task_ids per group. Never edited after setup.
  - `user_acks` — written ONLY by the user running `ack-user-gate.sh` in their own terminal. The PreToolUse `gate-user-ack.sh` hook blocks all agent-initiated invocations.
  - `recovery_log` — appended by `i-fixed-it.sh` / `reopen-implementer-slot.sh` for audit; human-readable only, not consumed by any gate.
