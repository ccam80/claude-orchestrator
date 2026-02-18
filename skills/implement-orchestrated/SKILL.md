---
name: implement-orchestrated
description: Execute implementation by spawning parallel orchestrator and implementer agents. Reads specs, manages wave execution order, tracks progress, and reports results.
argument-hint: <phase name or number, or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Task, AskUserQuestion]
---

# Implement Orchestrated

You are the top-level implementation coordinator. You read specs, spawn orchestrator agents per wave, and track progress across the full implementation.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to understand the full plan.
3. Read all phase spec files in `spec/` (files matching `spec/phase-*.md`).
4. Read the project's `CLAUDE.md` for project-specific rules.
5. Read `spec/progress.md` to determine what's already been implemented.
6. Read the following plugin references:
   - `${SKILL_DIR}/references/lock-protocol.md` — lock protocol
   - `${CLAUDE_PLUGIN_ROOT}/references/rules.md` — implementation rules
   - `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md` — orchestrator agent instructions
   - `${CLAUDE_PLUGIN_ROOT}/agents/implementer.md` — implementer agent instructions
7. If `$ARGUMENTS` specifies a phase, limit execution to that phase. Otherwise execute all phases in order.

## Wave Execution

### Determine Order
- Phases execute in dependency order (Phase 1 before Phase 2 if Phase 2 depends on Phase 1).
- Waves within a phase execute sequentially (Wave 1.1 before Wave 1.2) unless the spec explicitly marks them as parallelizable.
- Skip waves/tasks already marked complete in `spec/progress.md`.

### For Each Wave

#### 1. Build Orchestrator Prompt

Construct the orchestrator's prompt using this template. **Embed all context directly** — the orchestrator cannot read plugin files.

```markdown
# Wave Orchestration Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec
- **Lock Directory**: {project_dir}/spec/.locks

## Wave {wave_id}: {wave_name}
- **Phase**: {phase_name}
- **Prerequisite waves**: {completed_wave_ids}
- **Max parallel implementers**: {max_parallel, default 4}

## Tasks
| ID | Title | Complexity | Model |
|----|-------|------------|-------|
| {id} | {title} | S/M/L | haiku/sonnet |

## Task Specifications
{full spec text for each task, copied verbatim from the phase spec file}

## Project Rules
{full contents of project CLAUDE.md}

## Implementation Rules
{full contents of references/rules.md}

## Implementer Agent Instructions
{full contents of agents/implementer.md — the entire file, so the orchestrator
can pass it to spawned implementer Tasks without reading plugin files}

## Lock Protocol
{full contents of references/lock-protocol.md}
```

**Complexity → model mapping**:
- S (Small) → haiku
- M (Medium) → sonnet
- L (Large) → sonnet

#### 2. Spawn Orchestrator

Spawn a single orchestrator Task with:
- **subagent_type**: `general-purpose`
- **model**: `opus`
- **prompt**: the constructed prompt above

The orchestrator agent instructions (embedded in the prompt) tell it how to spawn implementers, manage locks, and track progress.

#### 3. Process Results

After the orchestrator Task returns:
1. Read `spec/progress.md` for updated status.
2. Check whether all tasks in the wave are complete.
3. If all complete → proceed to next wave.
4. If partial completion:
   - Report the status to the user.
   - Ask whether to retry incomplete tasks or skip them.
   - If retry → spawn another orchestrator for the remaining tasks.
   - If skip → note skipped tasks and proceed.

### After All Waves

1. Run verification measures from `spec/plan.md`:
   - Execute any test commands specified.
   - Check acceptance criteria.
2. Report final status to the user:
   - Which phases/waves/tasks completed successfully.
   - Which tasks are partial or failed.
   - Test results.
   - Any issues encountered.

## Progress Tracking

`spec/progress.md` is the source of truth for implementation status. It is append-only — implementers add entries, never overwrite.

To check what's complete, read the file and look for task entries with `Status: complete`.

## Error Handling

- If an orchestrator Task fails (returns error), report to the user and ask how to proceed.
- If progress.md shows persistent failures, surface the details to the user.
- Never silently skip failed tasks — always report and get user direction.

## Important

- You MUST embed all context (rules, lock protocol, implementer instructions, project CLAUDE.md) directly into the orchestrator prompt. Orchestrators and implementers cannot read plugin files.
- You MUST read the implementer agent file and include its FULL contents in the orchestrator prompt. The orchestrator needs this to construct implementer prompts.
- The lock protocol file in `${SKILL_DIR}/references/lock-protocol.md` is the canonical reference. Include it verbatim.
- Do not implement tasks yourself. Your job is to coordinate — read specs, spawn orchestrators, track progress, report to user.
