---
name: plan-spec
description: Take a phase from the implementation plan and produce a detailed implementation spec through collaborative architecting. Every design decision goes through the user.
argument-hint: <phase name or number>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Task]
---

# Plan Spec

You are producing a detailed implementation specification for a single phase from the project's implementation plan. You work collaboratively with the user — every design decision goes through them.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to find the phase to spec.
3. If `$ARGUMENTS` specifies a phase (by name or number), use that. Otherwise ask the user which phase to spec.
4. Read any existing phase specs in `spec/` to understand what's already been designed.
5. Read the project's `CLAUDE.md` for project-specific conventions.
6. Read relevant source files to understand the existing codebase.
7. Read the spec template from `${SKILL_DIR}/references/spec-template.md`.

## Workflow

For each wave and task in the phase:

### 1. Present the Design Space
- Identify the key design decisions for this task.
- Present options and tradeoffs as a table.
- Surface architecture tensions explicitly: "This conflicts with X because..."
- Highlight constraints from the project's CLAUDE.md or existing code.

### 2. Get User Decision
- Wait for the user to decide on each design choice.
- Do not proceed past a decision point without user input.

### 3. Incorporate the Decision
- Write the decision directly into the spec as a current-state fact.
- The spec reflects outcomes, not history. No "we considered X but chose Y."
- If a decision changes mid-session, update the spec in place — replace, don't append.

### 4. Check Ripple Effects
- After each decision, check whether it affects other tasks in this phase or other phases.
- If it does, note the impact and update the spec accordingly.
- If it affects a different phase's spec, note it for the user but don't modify other spec files.

### 5. Define Specifics
For each task, define:
- **Files to create**: exact paths, purpose, key classes/functions to define
- **Files to modify**: exact paths, what to change, specific functions affected
- **Tests**: exact test paths, class names, method names, and what each test asserts
- **Acceptance criteria**: concrete, testable statements

## Spec File Principle

Spec files are current-state contracts. They contain ONLY what to build:
- No decision history
- No changelogs
- No "previously we considered X"
- No "this was changed from Y to Z"

If a decision changes mid-session, the spec is updated in place. The final spec reads as if the current design was always the plan.

## Output

After all tasks are specced, present the complete spec for user review. Then write the approved spec to:

```
spec/phase-{n}-{name}.md
```

Where `{n}` is the phase number and `{name}` is the phase name in kebab-case (lowercase, hyphens for spaces).

Use the format from `${SKILL_DIR}/references/spec-template.md`.

## Important

- Tests must specify exact assertions, not vague "test that it works" statements.
- File paths must be specific — no "somewhere in the utils directory."
- Acceptance criteria must be concrete enough that a different person could verify them.
- Every task must have at least one test specified.
- Keep the spec focused on WHAT to build, not HOW to build it (implementation details are left to the implementer unless architecturally significant).
