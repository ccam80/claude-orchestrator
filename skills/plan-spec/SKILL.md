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

## Author Authority

The implementation plan (`spec/plan.md`) is agent-generated. There is no guarantee of correctness until decisions have been explicitly made by the author (the user). The author is the authoritative source of truth on architectural and implementation decisions.

- When a plan decision seems wrong, incomplete, or in tension with the codebase, **say so**. It is expected and encouraged to question the sanity and correctness of the plan during spec work.
- If a spec decision contradicts or improves upon the plan, **update `spec/plan.md` retroactively** to reflect the better decision. The plan is a living document that should match reality, not a frozen contract.
- Never treat the plan as gospel. Treat it as the best guess at time of writing, subject to revision as you dig into details.

## How to Refer to Tasks

Never refer to a task by number or title alone (e.g. "Task 2.1.3" or "the serialization task"). The user does not have the entire plan in memory. Always describe the task's contents and context when discussing it. For example: "the task that adds JSON serialization to the config loader (`config/loader.py`)" rather than "Task 2.1.3."

## How to Present Decisions

**Do not use AskUserQuestion for design decisions.** Interview-style questions force binary or ternary choices, often based on flawed assumptions, and the answer is most often "none of the above" or "some of each."

Instead, present decisions conversationally:

1. **Lay out the design space in prose.** Describe the options, what each implies, and where the tensions are. Use tables for comparing concrete tradeoffs, but wrap them in explanatory text.
2. **Be explicit about what's at stake.** "If we go with X, that means Y for the rest of the system. If we go with Z, we get A but lose B."
3. **End with a recap list of the specific questions** the user needs to answer, so they can respond point-by-point without re-reading the whole discussion.

This gives the user room to say "actually, a mix of options 1 and 3" or "you're missing an option entirely" — which structured interviews prevent.

## Workflow

For each wave and task in the phase:

### 1. Present the Design Space
- Describe the task's purpose and context (never just its number/title).
- Identify the key design decisions for this task.
- Present options and tradeoffs in prose, using tables for concrete comparisons.
- Surface architecture tensions explicitly: "This conflicts with X because..."
- Highlight constraints from the project's CLAUDE.md or existing code.
- If the plan's approach for this task seems wrong or suboptimal, flag it now.

### 2. Get User Decision
- End your design space presentation with a numbered recap of the specific questions.
- Wait for the user to decide on each design choice.
- Do not proceed past a decision point without user input.

### 3. Incorporate the Decision
- Write the decision directly into the spec as a current-state fact.
- The spec reflects outcomes, not history. No "we considered X but chose Y."
- If a decision changes mid-session, update the spec in place — replace, don't append.
- If the decision contradicts the plan, update `spec/plan.md` to match.

### 4. Check Ripple Effects
- After each decision, check whether it affects other tasks in this phase or other phases.
- If it does, note the impact and update the spec accordingly.
- If it affects a different phase's spec, note it for the user but don't modify other spec files.
- If it affects the plan itself, update `spec/plan.md` to reflect the new reality.

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

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths.
- **Use `/dev/null`**, never `NUL`.

## Important

- Tests must specify exact assertions, not vague "test that it works" statements.
- File paths must be specific — no "somewhere in the utils directory."
- Acceptance criteria must be concrete enough that a different person could verify them.
- Every task must have at least one test specified.
- Keep the spec focused on WHAT to build, not HOW to build it (implementation details are left to the implementer unless architecturally significant).
