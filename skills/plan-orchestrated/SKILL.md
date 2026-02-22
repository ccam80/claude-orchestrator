---
name: plan-orchestrated
description: Generate a high-level implementation plan with phases, waves, and verification measures. Collaboratively define goals, scope, and task structure with the user.
argument-hint: <feature or task to plan>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Task, EnterPlanMode]
---

# Plan Orchestrated

You are generating a high-level implementation plan for a software feature or task. You work collaboratively with the user — every major decision goes through them.

## Setup

1. Determine the project root directory. If `$ARGUMENTS` specifies a directory, use it. Otherwise use the current working directory.
2. Read the project's `CLAUDE.md` if it exists.
3. Read any existing files in `spec/` to understand prior plans and specs.
4. Read the plan template from `${SKILL_DIR}/references/plan-template.md`.

## Author Authority

The plan you produce is agent-generated. There is no guarantee of correctness until decisions have been explicitly made by the author (the user). The author is the authoritative source of truth on all architectural and implementation decisions in the plan.

- Do not introduce approval tracking, sign-off checkboxes, or status fields into the plan document. Authority is social, not procedural.
- Present decisions and recommendations, but frame them as proposals for the author to confirm or override.
- The plan will be revised during spec work if spec-level decisions reveal better approaches. This is expected and correct.

## How to Refer to Tasks

Never refer to a task by number or title alone (e.g. "Task 2.1.3" or "the serialization task"). The user does not have the entire plan in memory. Always describe the task's contents and context when discussing it.

## How to Present Decisions

**Do not use AskUserQuestion for design decisions.** Interview-style questions force binary or ternary choices, often based on flawed assumptions, and the answer is most often "none of the above" or "some of each."

Instead, present decisions conversationally:

1. **Lay out the design space in prose.** Describe the options, what each implies, and where the tensions are. Use tables for comparing concrete tradeoffs, but wrap them in explanatory text.
2. **Be explicit about what's at stake.** "If we go with X, that means Y for the rest of the system. If we go with Z, we get A but lose B."
3. **End with a recap list of the specific questions** the user needs to answer, so they can respond point-by-point without re-reading the whole discussion.

This gives the user room to say "actually, a mix of options 1 and 3" or "you're missing an option entirely" — which structured interviews prevent.

## Workflow

### 1. Requirements Gathering
- If `$ARGUMENTS` contains a feature description, use it as the starting point.
- Clarify requirements conversationally — lay out what you understand, what's ambiguous, and what you'd like the user to confirm. End with a recap of specific questions.
- Keep the discussion focused and efficient.

### 2. Plan Development
Work through these elements collaboratively with the user.

**Every plan MUST include these mandatory phases:**

#### Mandatory Phase 0: Dead Code Removal
The first phase of every plan is a complete removal of all code, tests, references, and imports that will become dead or stale as a result of the planned work. This phase:
- Runs before any plan-spec agents, so they never see legacy code in their context.
- Identifies all code paths, tests, imports, type references, config entries, and documentation that will be replaced or made obsolete by the planned implementation.
- Removes them entirely. This will break things — that is expected and correct.
- Is a single-wave phase with no dependencies, executed first.

Skipping this step causes planning agents to include legacy code in their context, which waters down plans and leads to backwards-compatibility shims. This phase is non-negotiable.

#### Mandatory Final Phase: Legacy Reference Review
The last phase of every plan is a complete audit for any remaining legacy references. This phase:
- Runs after all implementation phases are complete.
- Searches the entire repository for stale references to removed code: imports, type annotations, string literals, config values, documentation, test fixtures, and comments.
- No legacy references are acceptable in any form.
- Reports findings and removes any that are found.


**Goals**: Define concrete, measurable deliverables. Each goal should be something you can point to and say "this exists and works."

**Non-Goals**: Explicitly exclude things that might seem in scope but aren't. This prevents scope creep during implementation.

**Phases**: Group related work into phases numbered in **execution order**, not conceptual grouping. Phases that can start in parallel after the same dependency should have consecutive numbers. For example, if Phases A, B, and C all depend only on Phase 1, they should be numbered 2, 3, 4 — not 2, 3, 7. The numbering must reflect when work can actually begin, so a reader can see at a glance which phases are parallelizable and which are sequential.

Each phase should be independently verifiable — when it's done, you can confirm it works without needing later phases.

Include a **dependency graph** in the plan showing the execution topology. Use a simple ASCII diagram showing which phases depend on which, and which can run in parallel. Example:

```
Phase 1 (Foundation)
├──→ Phase 2 (Foo)        ─── parallel after 1 ──┐
├──→ Phase 3 (Bar)        ─── parallel after 1    │
│                                                  │
│    Phase 4 (Baz)        ─── after 3              │
│                                                  │
└──→ Phase 5 (Qux)       ─── after 4 + 2 ─────────┘
```

**Waves**: Within each phase, group tasks into waves. Tasks within a wave can potentially be implemented in parallel. Tasks in later waves depend on earlier waves completing.

**Tasks**: Each task is a discrete unit of work. For each task, define:
- A clear description of what to build
- Complexity rating: S (small/simple), M (medium), L (large/complex)
- Key files that will be created or modified

**Verification**: Define how to confirm each phase is correct. These should be concrete, runnable checks — not vague statements like "it works."

### 3. Complexity Ratings
Complexity ratings drive implementer model selection during implementation:
- **S** (Small): Single-file changes, straightforward logic, clear patterns to follow → haiku
- **M** (Medium): Multi-file changes, some design decisions, moderate complexity → sonnet
- **L** (Large): Architectural decisions, complex logic, cross-cutting concerns → sonnet

### 4. Review and Write
- Present the complete plan to the user for review.
- Incorporate any feedback.
- Create `spec/` directory if it doesn't exist: `mkdir -p spec`
- Write the approved plan to `spec/plan.md` using the template format.
- Initialize `spec/progress.md` with a header if it doesn't exist.

## Output

The plan is written to `spec/plan.md` following the template in `${SKILL_DIR}/references/plan-template.md`.

If `spec/progress.md` doesn't exist, create it:

```markdown
# Implementation Progress

Progress is recorded here by implementation agents. Each completed task appends its status below.
```

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths.
- **Use `/dev/null`**, never `NUL`.

## Important

- Present design options in prose with tables for concrete tradeoff comparisons — never as bare structured interviews.
- When describing tasks to the user, always include their content and context, not just their number or title.
- Surface dependencies between tasks explicitly.
- Keep task granularity appropriate — each task should be completable by a single agent in one session.
- Ensure wave ordering respects dependencies (a task can't use something built in a later wave).
