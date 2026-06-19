---
name: implement-hybrid
description: Execute implementation by driving a per-batch workflow that fans out implementers and verifiers, while the skill stays the human gateway for clarifications and user-required actions.
argument-hint: <phase name or number, or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Workflow]
---

# Implement Hybrid

You are the implementation coordinator and the human gateway. You read `spec/manifest.json`,
compute the batch schedule, then drive **one workflow invocation per batch**. The workflow
(`workflows/implement.mjs`) does all the headless work — spawning implementers, verifying
them, and running up to two fix rounds on failures. You handle the things a background
workflow cannot: surfacing clarifications and user-required actions to the user, updating
specs, committing, and moving to the next batch.

There is no state file, no spawn-gate hook, and no recording script. The workflow's
structured return is the record; `git` commits and `spec/progress.md` are the durable trail.

## Architecture

```
implement-hybrid skill (you — main loop, human gateway)
  └─ per batch: Workflow(workflows/implement.mjs)
        ├─ parallel implementers (one per task_group)
        ├─ parallel wave-verifiers (one per <=4 task_groups, phase-partitioned)
        └─ up to 2 headless fix rounds on FAIL
```

## Setup

1. Determine the project root (current working directory) and resolve the plugin root
   (`${CLAUDE_PLUGIN_ROOT}`) — you pass it into the workflow so agents can read
   `references/rules.md`.
2. Read `spec/manifest.json` — the job-control artifact. It contains, in execution order,
   every phase, its `depends_on`, its waves, the task_groups per wave, each task's
   `complexity`, each group's `user_required_tasks`, the `test_command`, and the final
   `verification` checks. This is the **only** input you need. Do not read `spec/plan.md`
   or the phase spec files yourself — the agents the workflow spawns read those.
   - Missing manifest, empty `phases`, any wave with empty `task_groups`, or any phase
     lacking a `depends_on` array → STOP and surface it as a planning failure. There is
     no fallback schedule.
3. If `$ARGUMENTS` names a phase, restrict scope to it: treat it as alone in its tier
   (prerequisites assumed complete from earlier runs per `spec/progress.md`), so its
   batches are just its own waves, unmerged.
4. Read `spec/progress.md` (if present) to see what is already complete and resume there.

## Compute the Batch Schedule

From `depends_on`, layer the in-scope phases into **tiers** (a phase's tier is
`1 + max(tier of its prerequisites)`; no-prerequisite phases are tier 0). Phases in a tier
are **siblings** and run concurrently — `review-spec` guarantees siblings are file-disjoint,
so this is safe. Within a tier, merge the *k*-th wave of every phase into **batch** *k*
(union of wave *k*'s task_groups across the tier's phases). Emit batches in tier order, then
position order; number them `batch-1 … batch-N`.

For each batch, assemble its `groups` array from the manifest — one entry per task_group:

```jsonc
{
  group_id, phase, spec_file,                 // spec_file = that group's origin phase's spec_file
  tasks: [{ id, title, complexity }],         // title from the phase spec; complexity from the manifest
  user_required_tasks: [taskId],              // verbatim from the manifest
  acked_user_tasks: []                        // you fill this as the user confirms actions (see gate below)
}
```

Copy task_groups verbatim from the manifest — never re-cluster, merge, split, or skip them.

## Test Baseline

Before the first batch, capture the pre-existing test state once so verifiers can tell
regressions from pre-existing failures. Run the manifest's `test_command` (use a background
Bash call if it is slow) and write `spec/test-baseline.md`:

```markdown
# Test Baseline
- **Timestamp**: {ISO 8601}
- **Command**: {test_command}
- **Result**: {pass}/{total} passing, {fail} failing

## Failing Tests (pre-existing)
| Test | Status | Summary |
|------|--------|---------|
```

If there is no test command, write that and continue.

## Batch Execution Loop

For each batch in order (a batch only starts after the previous one is fully PASSED):

### 1. Checkpoint and arm the scope guard

Parallel implementers and the workflow's headless fix rounds share one working tree. Two
mechanical protections bracket every batch — never skip them:

1. **Checkpoint.** Record the clean pre-batch commit so any out-of-scope damage is recoverable:
   ```bash
   git add -A && git commit -m "co: checkpoint before {batch_id}" --allow-empty -q
   CHECKPOINT=$(git rev-parse HEAD)
   ```
   (For batches after the first this is usually a no-op over the previous batch's completion
   commit — that is fine; `--allow-empty` keeps it uniform.)
2. **Arm the guard, but only for parallel batches.** If the batch has **2 or more**
   task_groups, write the sentinel that activates the destructive-command guard
   (`hooks/guard-destructive-fs.mjs`) for the duration of the workflow:
   ```bash
   mkdir -p .omc/state && printf 'active' > .omc/state/co-guard-active
   ```
   For a **single-group** batch (e.g. a solo Phase 0 dead-code-removal phase, where deleting
   whole files is the legitimate task) do **not** write the sentinel — there is no sibling
   agent to endanger, and the guard would block the spec'd deletions.

### 2. Invoke the workflow

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/implement.mjs",
  args: { project_dir, plugin_root, test_command, baseline_file: "spec/test-baseline.md", batch }
})
```

The workflow returns:

```jsonc
{
  batch_id,
  verdicts: { group_id: "PASS" | "FAIL" | "BLOCKED" | "DEAD" },
  blockers: [{ group_id, type: "clarification" | "user_action", detail }],
  failures: [{ group_id, reasons }],   // groups still FAIL after 2 fix rounds
  files:    { group_id: { created, modified } },
  scope_regressions: [{ group_id, regressions }]  // out-of-scope test failures agents refused to chase
}
```

### 3. Disarm the guard and audit scope

The moment the workflow returns, remove the sentinel (if you wrote one) and run the scope
audit against the checkpoint — **before** resolving blockers or committing:

```bash
rm -f .omc/state/co-guard-active
# write the workflow's returned `files` map to a temp file, then:
node "${CLAUDE_PLUGIN_ROOT}/scripts/scope-audit.mjs" \
  --checkpoint "$CHECKPOINT" --footprint /tmp/co-footprint.json --apply
```

The audit compares the working tree to the checkpoint and cross-references each group's
reported footprint. It exits `0` clean, `1` if it found and recovered violations, `2` if a
violation is **unrecoverable**. Act on the JSON it prints:

- **`deleted` / `modified-out-of-scope`** — a file outside the changing group's footprint was
  removed or edited. With `--apply` the audit restores deletions from the checkpoint; it only
  *reports* out-of-scope modifications (they may be legitimate-but-unreported edits). Surface
  every entry to the user — an agent reached outside its lane and the corresponding group's
  PASS is suspect; treat that group as FAIL and re-run it.
- **`created-then-deleted` with `recoverable: false` (exit 2)** — an agent created a file and
  another agent destroyed it before it was ever committed; it cannot be recovered. **STOP.**
  Report it to the user with the filename and the owning group; do not continue the run.

Also surface any `scope_regressions` the workflow returned: these are out-of-scope test
failures an implementer correctly refused to chase. Route each to the group that actually owns
the implicated file (re-run that group), never by having the reporting group touch it.

### 4. Resolve blockers (the human gate)

For every blocker:

- **`clarification`** — the implementer hit a spec ambiguity. Surface `detail` to the user
  verbatim (summary, the quoted spec text, the competing readings). Get the answer, **edit
  the phase spec file** to bake in the clarified wording, then re-invoke the workflow for a
  batch containing only that group. Repeat until it returns non-blocked.

- **`user_action`** — a task needs a real-world action only the user can perform. Present
  it via `AskUserQuestion`: state the exact action (`detail.action`) and what evidence to
  report. Do **not** ack on the user's behalf and do not stub or defer the task. When the
  user confirms they have done it, add that `task_id` to the group's `acked_user_tasks` and
  re-invoke the workflow for that group. The verifier FAILs any group whose user-required
  task is unacked, so a group cannot pass this gate without a genuine user confirmation.

A `DEAD` verdict means an implementer returned no result — re-invoke the workflow for that
group. After two `DEAD` rounds for the same group, stop and report to the user.

### 5. Handle persistent failures

If `failures` is non-empty (a group still FAILs after the workflow's two internal fix
rounds), STOP and report the reasons to the user. Ask how to proceed — do not silently
narrow scope or accept the failure.

### 6. Commit and continue

Once every group in the batch is `PASS` (and the scope audit is clean or fully recovered):

```bash
git add -A
git commit -m "Batch {batch_id} implementation complete"
```

Then proceed to the next batch. When a whole tier is done, append a short tier summary to
`spec/progress.md`.

## After All Phases

1. Run the manifest's `verification` checks (final acceptance criteria) and `test_command`.
2. Report final status: phases/batches/tasks completed, verification outcomes, test results.
3. Remove the baseline scratch file: `rm -f "spec/test-baseline.md"`.
4. Remove the scope-guard sentinel if it is still present: `rm -f .omc/state/co-guard-active`.
   Do this on **any** exit, including when you stop early on a blocker, persistent failure, or
   an unrecoverable scope violation — never leave the sentinel armed after the run ends.

## User-Required Task Gate

User-required tasks are **hard stop gates** (see `references/rules.md` §User-Required Tasks).
Under this runtime the gate is enforced by two things, no scripts required:

- The implementer returns `user_action_required` for such a task instead of completing it,
  and the workflow surfaces it as a blocker rather than verifying the group.
- The wave-verifier FAILs any group whose user-required task is not in `acked_user_tasks`.

Your responsibility: enumerate is already done by the manifest's `user_required_tasks`;
surface each action to the user via `AskUserQuestion`, never ack on their behalf, never
advance an unacked gate, and only add a task to `acked_user_tasks` after the user confirms.

## Important

- You never spawn implementers or verifiers directly — the workflow does. You compute the
  schedule, invoke the workflow per batch, resolve human blockers, and commit.
- You never read full git diffs (`git diff --shortstat` only) or the phase spec files
  (except to edit one when resolving a clarification).
- The manifest is immutable for the run — re-read it freely for static lookups.
- If context compresses, re-derive remaining work from `spec/progress.md` + git history and
  resume at the first batch whose groups are not all committed as complete.

## Shell Safety (Windows)

Git Bash on Windows. All bash commands: double-quote every path, use forward slashes, use
`/dev/null` not `NUL`, use Unix commands (`ls`, `rm`, `mkdir`).
