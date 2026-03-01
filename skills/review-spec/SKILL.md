---
name: review-spec
description: Review phase specs for quality, consistency, and implementability before implementation. Spawns parallel review agents per phase, performs cross-phase checks, and presents actionable findings.
argument-hint: <phase number(s), or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, TaskOutput, AskUserQuestion]
---

# Review Spec

You are the spec review coordinator. You read phase specs, spawn review-spec agents per phase, perform cross-phase consistency checks, and present consolidated findings with actionable fix suggestions.

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

After all agents return:
1. Collect the lean summaries (verdicts + tallies + critical issues).
2. Note which phases are `ready` vs `needs-revision`.

## Cross-Phase Checks

After all per-phase reviews complete, perform cross-phase checks yourself by reading the phase spec files. Check for:

### 1. Shared File Conflicts
- Identify files that appear in multiple phase specs (in "Files to create" or "Files to modify").
- Verify that modifications across phases are compatible — not contradictory.
- If two phases create the same file, flag it as a conflict.

### 2. Phase Dependency Respect
- Check the dependency graph from `spec/plan.md`.
- Verify no phase spec references outputs (files, functions, APIs) from a later phase.
- Verify dependent phases' specs are compatible with what their prerequisite phases produce.

### 3. No Duplicate Tasks
- Check that no task appears in multiple phase specs.
- Check that no two tasks across phases describe the same work with different IDs.

### 4. Plan Verification Achievability
- Check that the plan's verification measures (test commands, acceptance criteria) can be satisfied by the combined spec contents.
- Flag any verification measure that no spec task addresses.

## Combined Report

Write the combined report to `spec/reviews/spec-review-combined.md`:

```markdown
# Spec Review: Combined Report

## Overall Verdict: ready | needs-revision

## Per-Phase Verdicts
| Phase | Verdict | Coverage Gaps | Consistency | Completeness | Concreteness | Implementability |
|-------|---------|---------------|-------------|--------------|--------------|------------------|
| {n} — {name} | ready/needs-revision | {n} | {n} | {n} | {n} | {n} |

## Cross-Phase Issues

### Shared File Conflicts
{each conflict: which phases, which file, how they conflict. If none, write "None found."}

### Phase Dependency Violations
{each violation: which phase references what from which later phase. If none, write "None found."}

### Duplicate Tasks
{each duplicate: task IDs, phases, description overlap. If none, write "None found."}

### Unaddressed Verification Measures
{each plan verification measure not covered by any spec. If none, write "None found."}

## Per-Phase Details
{For each phase with issues, include the critical issues from the agent's lean summary}
```

## Present Findings

Present findings to the user organized by actionability:

### 1. Blocking Issues (must fix before implementation)
- Missing plan tasks (coverage gaps)
- Contradictory specs (internal consistency)
- Cross-phase file conflicts
- Phase dependency violations

### 2. Quality Issues (should fix for better implementation)
- Vague specs (concreteness)
- Missing test assertions or acceptance criteria (completeness)
- Implementability concerns

### 3. Informational
- Duplicate tasks across phases
- Unaddressed verification measures

For each finding, include:
- **Location**: which phase, which task, which section of the spec
- **Problem**: what's wrong
- **Suggestion**: what a concrete fix would look like

## Context Conservation

You are a coordinator. Protect your context:
- **ALWAYS use `run_in_background: true` on Task calls.**
- **Use `TaskOutput(block=true)` only.** Never poll with `block=false`.
- **Spawn-then-wait**: Spawn all review agents in one message, then `TaskOutput` each.
- **Read phase specs once** for cross-phase checks. Do not re-read for each check.
- Do not read the full report files during coordination — the lean summaries are sufficient. Read full reports only if you need detail for cross-phase analysis.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths, never backslashes.
- **Use `/dev/null`**, never `NUL`.
- **Invoke scripts with `bash` explicitly**.

## Important

- Run the materialize script during setup (step 5).
- Do not review specs yourself. Spawn review-spec agents for per-phase review. You only do cross-phase checks.
- Do not modify specs. Present findings and let the user decide what to fix.
- The `claude-orchestrator:review-spec` agent type provides full review-spec instructions automatically. Do not redundantly point agents to `spec/.context/review-spec.md` if using the agent type.
