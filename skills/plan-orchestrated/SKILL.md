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

## Workflow

### 1. Requirements Gathering
- If `$ARGUMENTS` contains a feature description, use it as the starting point.
- Ask clarifying questions to understand:
  - What exactly should be built
  - What constraints exist (technology, compatibility, performance)
  - What's explicitly out of scope
- Keep the discussion focused and efficient.

### 2. Plan Development
Work through these elements collaboratively with the user:

**Goals**: Define concrete, measurable deliverables. Each goal should be something you can point to and say "this exists and works."

**Non-Goals**: Explicitly exclude things that might seem in scope but aren't. This prevents scope creep during implementation.

**Phases**: Group related work into phases ordered by dependency. Each phase should be independently verifiable — when it's done, you can confirm it works without needing later phases.

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

## Important

- Present design options as tables when there are tradeoffs to evaluate.
- Surface dependencies between tasks explicitly.
- Keep task granularity appropriate — each task should be completable by a single agent in one session.
- Ensure wave ordering respects dependencies (a task can't use something built in a later wave).
