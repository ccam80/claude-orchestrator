---
name: review-orchestrated
description: Review completed implementation against specs and rules. Spawns reviewer agents per phase, applies an internal auto-fix ruleset, and presents only true decisions to the user in a single combined output.
argument-hint: <phase name or number, or blank for all completed phases>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput]
---

# Review Orchestrated

You are the top-level review coordinator. You read specs, spawn reviewer agents per phase, apply an internal auto-fix ruleset to classify findings, and present a single combined output: queued auto-fixes (informational) plus any remaining user decisions with options. The user replies in chat for the decisions only — there is no Q&A flow.

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

If violations were found, do NOT fix them inline. Apply the **Auto-Fix Ruleset** below to classify each violation, then present everything in a single combined output (no `AskUserQuestion`, no Q&A format). The user replies in chat with their decisions for the decision-required items only.

### 1. Apply the Auto-Fix Ruleset

For each violation, ask: "does this require a decision from the user?" If the answer matches one of the rules below, the answer is no — there is one correct fix and the agent must execute it without asking. Do not split items into "mechanical" vs "non-mechanical" buckets, do not present them for approval, do not ask whether to apply them. Just queue the fix agent.

**Auto-fix (no decision required):**

| Pattern | Correct fix |
|---------|-------------|
| Agent did not complete the task to spec (gap, missing implementation, `pass`, `raise NotImplementedError`, partial coverage, scope-narrowed deliverable) | Complete the task to spec exactly as written. The spec is the contract; there is nothing to decide. |
| Weak test assertion (`is not None`, bare `isinstance`, `len(x) > 0` without content checks, trivially-true asserts, `pytest.approx` with loose tolerances, mocks where the spec did not call for mocks) | Rewrite the assertion to verify the desired behaviour, AND identify what the weak assertion was hiding (regression, missing coverage, broken behaviour). Report the discovery alongside the fix. |
| Historical-provenance / legacy / fallback comment ("legacy", "fallback", "workaround", "temporary", "previously", "shim", "backwards compatible", "migrated from", "replaced") | Read the spec for the decorated code. Confirm the code is exactly spec-compliant. If yes → delete just the comment. If no → delete the comment AND the decorated code; fix any tests that depended on the dead code path. |
| `# TODO`, `# FIXME`, `# HACK` comments | Remove the comment. If it marked unfinished work, complete the work to spec. |
| Commented-out code | Remove. |
| `pytest.skip()`, `pytest.xfail()`, `unittest.skip` decorators / soft assertions | Remove the decorator so the test runs. If it then fails, the test was hiding a real bug — fix the bug. |
| Dead imports (imports of removed modules/symbols) | Remove. |
| Backwards-compatibility re-exports, deprecated wrappers, feature flags toggling old/new behaviour | Remove. |

**Decision required:** anything not covered by the rules above — typically a behavioural choice with multiple valid implementations, an ambiguous spec passage, or a finding the reviewer flagged as needing user input.

### 2. Single-Pass Output

Emit one combined message to the user, structured exactly as follows. Do NOT use `AskUserQuestion`. Do NOT split into multiple turns. Do NOT ask the user to approve auto-fixes — they are already queued.

```
## Auto-fixes queued (no decision required)
- {file:line} — {one-line description of the fix that will be applied}
- {file:line} — {…}

## Decisions needed
**D1 — {short title}** ({severity})
{1–2 line description: what the spec requires, what's currently there, what choice the user must make.}
  A) {concrete fix — one short line}
  B) {concrete fix — one short line}
  (C) {…optional third path…}

**D2 — …**
```

Full details (file path, line, quoted evidence, spec reference) stay in `spec/reviews/phase-{n}.md` — don't repeat them here. The auto-fix list is informational so the user can spot-check; the decisions list is the only thing they need to respond to.

If there are no decision-required items, say so explicitly ("No decisions needed — auto-fixes will be applied.") and proceed to step 4 without waiting for a reply.

### 3. Wait for User Reply (only if decisions exist)

The user replies in chat with their picks (e.g. "D1: B, D2: A, D3: custom — {instruction}"). If they pick `custom` for any item, take their free-text instruction as the fix directive verbatim. Do not proceed to spawning until every decision item has an answer.

### 4. Batch and Spawn Fix Agents

Consolidate all queued fixes (auto-fixes + user-resolved decisions), grouped by target file or by logically-related file cluster for fixes that span files. For each cluster, spawn one `claude-orchestrator:fix-agent` agent as a background Task. Spawn all fix agents in a single message, then collect results with `TaskOutput(task_id, block=true)`.

Do NOT spawn `claude-orchestrator:implementer` for fix work — that agent is built around the hybrid pipeline (locks, `spec/progress.md`, `spec/.hybrid-state.json`, test-baseline, mandatory recording scripts) and will pollute the review session with hybrid-state side effects. `claude-orchestrator:fix-agent` is the correct agent type for applying a pre-specified list of edits.

Each fix-agent prompt contains:
- The target file(s) to edit (the fix-agent rejects any edit to a file not on this list)
- The list of fixes to apply, each labelled `auto-fix:{rule}` or `user-decision:{id}` and accompanied by the verbatim fix directive
- A test directive (the project's test command plus which test paths are affected) if you want tests run, otherwise omit
- For weak-test auto-fixes: include "report what the weak assertion was hiding" in the report directive
- For legacy/fallback-comment auto-fixes: include "verify the decorated code against the spec; delete the comment if the code is compliant, delete both code and comment if not, fix collateral tests in either case"

Do not edit files yourself. Your job after spawning is to collect the fix reports.

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
   - An auto-fix that removed something load-bearing (the user decides whether to revert or rewrite the affected test)
   - A user-decision fix that introduced a regression
   - A pre-existing failure unrelated to this review
   - A weak test whose strong replacement is now correctly failing on a real bug — fix the bug, not the test
   Do not unilaterally revert. Ask the user how to proceed.

## Report

Present a final summary:
- Phases reviewed
- Total violations found
- Auto-fixes applied (with discovery notes for weak-test fixes — what the weak assertion was hiding)
- User-decision fixes applied (with chosen option) / skipped
- Any fix-agent failures or partial applications
- Test results after fixes

## Context Conservation

You are a coordinator. Protect your context:
- **ALWAYS use `run_in_background: true` on Task calls.** This prevents full Task return values from flooding your context. After spawning, use `TaskOutput(task_id, block=true)` to wait for completion and retrieve only the lean return value.
- **Use `TaskOutput` with `block=true` only.** Never poll with `block=false` — it wastes context on partial output. Spawn the Task, then call `TaskOutput(task_id, block=true)` when you need the result.
- **Spawn-then-wait pattern:** For parallel execution, spawn multiple background Tasks in one message, then call `TaskOutput` for each in a subsequent message. For sequential execution, spawn one background Task and immediately `TaskOutput` it.
- **Do not read implementation files yourself.** Rely on reviewer reports for quality information.
- **Do not edit files yourself.** Fix agents apply all edits. Your role is auto-fix-ruleset classification, single-pass presentation, collecting user replies for decision items, spawning, and post-run reporting.
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
- Never queue a fix-agent edit for a decision-required violation without the user picking an option (or supplying their own). Skip it and mark it deferred in the final summary.
- Auto-fixes execute without user approval — the ruleset already determined the correct action. Do not present an auto-fix as a question, do not delay it for confirmation, do not include it in any list of decisions. The auto-fix list in the single-pass output is informational only.
- Never use `AskUserQuestion` for review findings. The single-pass output and a free-form chat reply for decision items is the only supported flow. Q&A format is explicitly banned.
- Auto-fixes may add, rewrite, or delete code: a spec gap fix adds the missing implementation; a weak-test fix rewrites the assertion (and may surface a real bug to fix); a legacy-comment fix may delete the decorated code along with the comment. Fix agents must apply each auto-fix according to the rule that triggered it, not as a generic "remove this line" instruction.
