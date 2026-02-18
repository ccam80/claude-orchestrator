# Handoff Templates

## implement-orchestrated → orchestrator

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
{full spec text for each task, copied from phase spec file}

## Project Rules
{contents of project CLAUDE.md}

## Implementation Rules
{contents of references/rules.md}

## Implementer Agent Instructions
{full contents of agents/implementer.md body — embedded so orchestrator
can pass them to spawned implementer Tasks without reading plugin files}

## Lock Protocol
{contents of references/lock-protocol.md}
```

## orchestrator → implementer

```markdown
# Implementation Assignment

## Project Root: {project_dir}
## Spec Directory: {project_dir}/spec

## Your Task
{full task spec — ID, description, files, tests, acceptance criteria}

## Available Tasks (for self-continuation)
| ID | Title | Complexity |
|----|-------|------------|
{remaining tasks in wave}

## Full Task Specs
{specs for all available tasks, so agent can self-continue without reading files}

## Lock Protocol
{lock protocol}

## Implementation Rules
{rules}

## Project Rules
{project CLAUDE.md content}

## Completion Protocol
After each task:
1. Append to spec/progress.md (never overwrite)
2. Release all locks
3. Check for available tasks (no existing lock dir in spec/.locks/tasks/{id})
4. If available and context allows → continue
5. If done → return completion report
```

## implementer → orchestrator (return via Task result)

```markdown
# Completion Report

## Tasks Completed
| ID | Status | Tests |
|----|--------|-------|
| {id} | complete/partial | {pass}/{total} |

## Details per Task
### Task {id}
- Files created: {list}
- Files modified: {list}
- Tests written: {list}
- If partial: {what remains — detailed enough for a fresh agent}

## Locks Released: all
```
