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
- `spec/.context/rules.md` — implementation rules (apply to all agents, includes Windows shell safety rules)
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
- `spec/.context/rules.md` — implementation rules (includes Windows shell safety rules — follow them)
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

## Report Path
Write your full report to: `spec/reviews/wave-{wave_id}.md`

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
# Review Summary: Wave {wave_id}

## Verdict: clean | has-violations

## Tally
| Category | Count |
|----------|-------|
| Violations — critical | {n} |
| Violations — major | {n} |
| Violations — minor | {n} |
| Gaps | {n} |
| Weak tests | {n} |
| Legacy references | {n} |

## Critical Findings
{Full details of critical-severity violations ONLY. Use the per-finding format below. If none, write "None."}

### {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical

## Full Report
`spec/reviews/wave-{wave_id}.md`
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

## Report Path
Write your full report to: `spec/reviews/phase-{n}.md`

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
# Review Summary: Phase {n} — {phase_name}

## Verdict: clean | has-violations

## Tally
| Category | Count |
|----------|-------|
| Violations — critical | {n} |
| Violations — major | {n} |
| Violations — minor | {n} |
| Gaps | {n} |
| Weak tests | {n} |
| Legacy references | {n} |

## Critical Findings
{Full details of critical-severity violations ONLY. If none, write "None."}

### {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical

## Full Report
`spec/reviews/phase-{n}.md`
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

## reviewer: full report file format

This is the format the reviewer writes to its `report_path` file. It contains every individual finding — never aggregated.

```markdown
# Review Report: {scope}

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

## implement-orchestrated: phase review combination

After all waves in a phase complete, combine wave review files into a single phase report.

### Input
All wave review files for the phase: `spec/reviews/wave-*.md` matching the phase's wave IDs.

### Output file
`spec/reviews/phase-{n}-combined.md`

### Output format

```markdown
# Combined Review: Phase {n} — {phase_name}

## Summary
- **Waves reviewed**: {list of wave IDs}
- **Total violations**: {n} (critical: {n}, major: {n}, minor: {n})
- **Total gaps**: {n}
- **Total weak tests**: {n}
- **Total legacy references**: {n}
- **Verdict**: clean | has-violations

## Violations
{All violations from all wave reports, prefixed with wave ID}

### [Wave {wave_id}] {V1}: {Short description}
- **File**: `{path}`:{line}
- **Rule**: {which rule is violated}
- **Evidence**: `{the offending code or comment, quoted}`
- **Severity**: critical | major | minor

## Gaps
{All gaps from all wave reports, prefixed with wave ID}

## Weak Tests
{All weak tests from all wave reports, prefixed with wave ID}

## Legacy References
{All legacy references from all wave reports, prefixed with wave ID}
```
