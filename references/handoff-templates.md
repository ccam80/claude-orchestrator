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
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Prerequisite waves**: {completed_wave_ids}
- **Max parallel implementers**: {max_parallel, default 4}

## Tasks
| ID | Title | Complexity | Model |
|----|-------|------------|-------|
| {id} | {title} | S/M/L | haiku/sonnet |

## Context Files
Read these files before doing anything else:
- `spec/.context/orchestrator.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules (apply to all agents)
- `spec/.context/lock-protocol.md` — lock protocol for parallel coordination
- `spec/.context/implementer.md` — implementer agent instructions (for constructing implementer prompts)
- `spec/phase-{n}-{name}.md` — full task specifications for this wave
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — current implementation status
```

## orchestrator → implementer

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
{remaining tasks in wave}

## Context Files
Read these files before doing anything else:
- `spec/.context/implementer.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules
- `spec/.context/lock-protocol.md` — lock protocol
- `spec/phase-{n}-{name}.md` — full task specifications (find your task by ID)
- `CLAUDE.md` — project-specific rules and conventions
```

## implement-orchestrated → reviewer

```markdown
# Wave Review Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Wave {wave_id}: {wave_name} (just completed)
- **Phase**: {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md

## Wave Completion Report
{the completion report returned by the orchestrator for this wave —
task statuses and test result counts. For file lists, read spec/progress.md directly.}

## Context Files
Read these files before doing anything else:
- `spec/.context/reviewer.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules to check against
- `spec/phase-{n}-{name}.md` — task specifications for the reviewed wave
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
```

## reviewer → implement-orchestrated (return via Task result)

```markdown
# Review Report: Wave {wave_id}

## Summary
- **Tasks reviewed**: {count}
- **Violations found**: {count}
- **Gaps found**: {count}
- **Verdict**: clean | has-violations

## Violations

### {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical | major | minor

## Gaps

### {G1}: {Short description}
- **Spec requirement**: {what the spec says}
- **Actual state**: {what was found}
- **File**: `{path}`

## Weak Tests

### {T1}: {Short description}
- **Test**: `{test_path}::{class}::{method}`
- **Issue**: {what's wrong with the assertion}
- **Evidence**: `{the assertion, quoted}`

## Legacy References

### {L1}: {Short description}
- **File**: `{path}`:{line}
- **Reference**: `{the stale reference, quoted}`
```

## review-orchestrated → reviewer

```markdown
# Phase Review Assignment

## Project
- **Root**: {project_dir}
- **Spec Directory**: {project_dir}/spec

## Review Scope: Phase {n} — {phase_name}
- **Phase spec file**: spec/phase-{n}-{name}.md
- **Tasks in scope**: all completed tasks for this phase

## Context Files
Read these files before doing anything else:
- `spec/.context/reviewer.md` — your agent instructions
- `spec/.context/rules.md` — implementation rules to check against
- `spec/phase-{n}-{name}.md` — task specifications for this phase
- `CLAUDE.md` — project-specific rules and conventions
- `spec/progress.md` — implementation status (source of truth for file lists)
```

## reviewer → review-orchestrated (return via Task result)

```markdown
# Review Report: Phase {n} — {phase_name}

## Summary
- **Tasks reviewed**: {count}
- **Violations found**: {count}
- **Gaps found**: {count}
- **Verdict**: clean | has-violations

## Violations

### {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical | major | minor

## Gaps

### {G1}: {Short description}
- **Spec requirement**: {what the spec says}
- **Actual state**: {what was found}
- **File**: `{path}`

## Weak Tests

### {T1}: {Short description}
- **Test**: `{test_path}::{class}::{method}`
- **Issue**: {what's wrong with the assertion}
- **Evidence**: `{the assertion, quoted}`

## Legacy References

### {L1}: {Short description}
- **File**: `{path}`:{line}
- **Reference**: `{the stale reference, quoted}`
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
