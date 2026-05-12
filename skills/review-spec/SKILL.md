---
name: review-spec
description: Review phase specs for quality, consistency, and implementability before implementation. Spawns parallel review agents per phase, performs cross-phase checks, and presents actionable findings.
argument-hint: <phase number(s), or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
---

# Review Spec

You are the spec review coordinator. You spawn review-spec agents per phase, consume their full reports directly from Task output, perform cross-phase consistency checks, and present a single consolidated set of findings split into Mechanical fixes and Decision-Required items. You are also the interface and the fixer — you apply Mechanical fixes (with user approval) and surface Decision-Required items with options for the user to choose between.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to understand the full plan — phases, dependencies, tasks per phase.
3. Read all phase spec files in `spec/` (files matching `spec/phase-*.md`).
4. Read the project's `CLAUDE.md` for project-specific rules.
5. Materialize shared context files for agents by running:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/materialize-context.sh" review-spec "${CLAUDE_PLUGIN_ROOT}" "{project_root}"
   ```
   This copies `rules.md` and `review-spec.md` to `spec/.context/`.
6. If `$ARGUMENTS` specifies phase(s), limit review to those phases. Otherwise review all phases.

## Per-Phase Review

### Spawn Review Agents

For each phase in scope, spawn one review-spec agent as a background Task:

- **subagent_type**: `claude-orchestrator:review-spec`
- **model**: `sonnet`
- **run_in_background**: `true`
- **description**: `"Review spec phase {n}"`

Use this prompt template for each agent:

```markdown
# Spec Review Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Review Scope: Phase {n} — {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Plan file**: spec/plan.md

## Report Path
Write your full report to: `spec/reviews/spec-phase-{n}.md`

## Context Files
Read these files before doing anything else:
- `spec/.context/review-spec.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules that specs must support
- `spec/plan.md` — full plan (for plan coverage checks)
- `spec/phase-{n}-{name}.md` — the phase spec to review
- `CLAUDE.md` — project-specific rules and conventions
```

Spawn all review agents **in a single message**. Then call `TaskOutput(task_id, block=true)` for each in a follow-up message.

### Collect Results

After all agents return, you have each phase's full report (Findings table + Decision-Required items) in your context already — the agent returned the full report as its Task output. Do NOT re-read the report files from disk; that is the context burn we are eliminating.

## Cross-Phase Checks

Perform these against the phase spec files (read each spec at most once) plus the per-phase reports you already have:

### 1. Shared File Conflicts
- Read each phase spec's **Files Owned** section. That is the phase's authoritative file footprint — the deduplicated union of every task's Files to create + Files to modify.
- Take the set intersection across phase pairs. Any file appearing in more than one feature phase's **Files Owned** is a finding. (Phase 0 Dead Code Removal and the Legacy Reference Review phase are exempt — they span arbitrary files by design.)
- If a phase spec is missing its **Files Owned** section, flag that as a `critical` finding — the phase cannot be cross-checked. Do not attempt to rebuild the footprint by scraping individual task bodies; that defeats the point of the section.
- For each shared file: if both phases only modify it in compatible additive ways (e.g. adding two different functions), note it but classify as `info`. If they create the same file, modify the same function/region, or one's modifications depend on the other's (which the dependency graph should have caught), flag as `critical`.

### 2. Phase Dependency Respect
- Check the dependency graph from `spec/plan.md`.
- No phase spec may reference outputs (files, functions, APIs) from a later phase.
- Dependent phases' specs must be compatible with what their prerequisite phases produce.

### 3. No Duplicate Tasks
- No task should appear in multiple phase specs.
- No two tasks across phases should describe the same work with different IDs.

### 4. Plan Verification Achievability
- The plan's verification measures must be satisfied by the combined spec contents.
- Flag any verification measure that no spec task addresses.

Classify every cross-phase finding as Mechanical or Decision-Required using the same definitions the per-phase agents use (see `agents/review-spec.md`). Most cross-phase findings will be Decision-Required (which phase owns the duplicate task, how to resolve a file conflict, etc.).

## Aggregate and Cross-Check

Before writing the combined report:

1. **Deduplicate**: if two per-phase reports flag the same underlying issue (e.g., both Phase 2 and Phase 3 mention they both create `src/auth.py`), merge them into one finding.
2. **Promote severity on conflict**: if a per-phase finding is `minor` in isolation but conflicts with another phase's spec, promote it to at least `major`.
3. **Re-classify on conflict**: a Mechanical fix in one phase may become Decision-Required if the cross-phase view introduces ambiguity (e.g., "rename to plan's ID" is mechanical until two phases both want that ID).
4. **Stable IDs**: rewrite finding IDs as `P{phase}-M{n}` for mechanical and `P{phase}-D{n}` for decision-required; cross-phase findings get `X-M{n}` / `X-D{n}`.

## Combined Report

Write to `spec/reviews/spec-review-combined.md`:

```markdown
# Spec Review: Combined Report

## Overall Verdict: ready | needs-revision

## Per-Phase Verdicts
| Phase | Verdict | critical | major | minor | info |
|-------|---------|----------|-------|-------|------|
| {n} — {name} | ready/needs-revision | {n} | {n} | {n} | {n} |

## Mechanical Fixes (apply with user approval)
| ID | Severity | Phase | Location | Problem | Proposed Fix |
|----|----------|-------|----------|---------|--------------|
| P2-M1 | major | 2 | phase-2 §Task 4 | … | … |
| X-M1  | minor | cross | phase-2, phase-3 | … | … |

## Decision-Required Items (user must choose)
### P2-D1 — {short title} ({severity})
- **Phase / Location**: …
- **Problem**: …
- **Why decision-required**: …
- **Options**: A / B / (C) with pros & cons (verbatim from per-phase report, edited only for cross-phase context)

### X-D1 — {short title} ({severity})
…
```

## Present Findings to User

Present all findings in a single pass, then collect all user answers in one batch before spawning fix agents. Do NOT apply edits one-by-one and do NOT defer Decision-Required items until after Mechanical fixes are applied — everything is answered together, then executed together.

### 1. Mechanical Fixes Table

Show the full Mechanical Fixes table from the combined report. This is presentation only — no approval is requested here in isolation. The user will approve/subset in step 3.

### 2. Decision-Required Items (compact)

For each Decision-Required item, present in this compact format (no long pros/cons — the full report at `spec/reviews/spec-phase-{n}.md` has those if the user wants them):

```
**{ID} — {short title}** ({severity})
{1–3 line description of the problem and why it needs a decision.}
Options:
  A) {concrete fix — one short line}
  B) {concrete fix — one short line}
  (C) {concrete fix — one short line, if a meaningfully distinct third path exists}
```

### 3. Collect All Answers in One Batch

Issue a single `AskUserQuestion` call containing:
- One question: "Approve Mechanical fixes?" — choices: `all` / `subset (list IDs)` / `none`
- One question per Decision-Required item: which option — choices: `A` / `B` / `C` / `skip` / `custom (user writes instruction)`

Do not proceed until you have an answer for the mechanical-approval question AND every Decision-Required item. If the user picks `custom`, take their free-text instruction as the fix directive verbatim.

### 4. Batch and Spawn Fix Agents

Consolidate all approved fixes, grouped by spec file. For each spec file that needs edits, spawn one `claude-orchestrator:fix-agent` agent as a background Task. Spawn all fix agents in a single message, then collect results with `TaskOutput(task_id, block=true)`.

Do NOT spawn `claude-orchestrator:implementer` for spec-file edits — that agent is built around the hybrid implementation pipeline (locks, `spec/progress.md`, hybrid state) and will create lock directories and progress entries that don't belong in a spec-review session. `claude-orchestrator:fix-agent` is the correct agent type.

Each fix-agent prompt contains:
- The spec file path to edit (single-file target list)
- The list of approved Mechanical edits, each labelled `auto-fix:mechanical:{id}` with verbatim before/after text from the Proposed Fix column
- The list of resolved Decision-Required edits, each labelled `user-decision:{id}` with the user's chosen option (or their custom free-text instruction) as the edit directive
- No test directive (spec files don't have tests)
- A report directive: "summarise what changed in line-by-line terms"

### 5. Final Summary
- Mechanical fixes applied / skipped (count by phase)
- Decision-Required items resolved / skipped (count by phase)
- Any edits the fix agents reported they couldn't apply, with reason
- Whether the overall verdict is now `ready` or still `needs-revision`

## Context Conservation

You are the interface AND the fixer — but still keep context lean:
- **ALWAYS use `run_in_background: true` on Task calls.**
- **Use `TaskOutput(block=true)` only.** Never poll with `block=false`.
- **Spawn-then-wait**: Spawn all review agents in one message, then `TaskOutput` each.
- The agent's Task output IS the full report. Do not re-read the report files from disk during aggregation.
- Read each phase spec at most once during cross-phase checks. Read it again only when actually applying a fix to that file.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths, never backslashes.
- **Use `/dev/null`**, never `NUL`.
- **Invoke scripts with `bash` explicitly**.

## Important

- Run the materialize script during setup (step 5).
- Do not review specs yourself. Spawn review-spec agents for per-phase review. You do cross-phase checks, aggregation, and the user-facing decision loop.
- You do NOT apply edits yourself. Present findings in one pass, collect all user answers in one batched `AskUserQuestion`, then spawn `claude-orchestrator:fix-agent` agents (one per target spec file) to apply the approved edits.
- Never queue a fix-agent edit for a Decision-Required item without the user picking an option (or supplying their own). "Probably option A" is not approval — skip it and report it as deferred.
- Agent instructions are delivered via the `spec/.context/` copies produced by `materialize-context.sh`. The agent type does not bypass this — every review-spec agent reads `spec/.context/review-spec.md` as its first action, as the prompt template directs.
