# Handoff Templates

These templates are used by the review pipeline. Implementation prompts (coordinator → implementer, coordinator → wave-verifier) are defined inline in `skills/implement-hybrid/SKILL.md`.

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
