# Claude Orchestrator

A Claude Code plugin for structured planning and parallel implementation of software features. Breaks large features into phased plans, detailed specs, and parallel implementation waves with automated review — driven by deterministic **workflows** that fan out specialized agents.

## Skills (User-Invocable Commands)

The plugin provides five skills, organized into three workflows:

### Planning

| Skill | Command | Purpose |
|-------|---------|---------|
| **plan-orchestrated** | `/claude-orchestrator:plan-orchestrated` | Generate a high-level implementation plan with phases, waves, and verification measures. Collaboratively define goals, scope, and task structure with the user. |
| **plan-spec** | `/claude-orchestrator:plan-spec` | Take a phase from the plan and produce a detailed implementation spec. Every design decision goes through the user. Writes `spec/manifest.json`, the job-control artifact. |

### Implementation

| Skill | Command | Purpose |
|-------|---------|---------|
| **implement-hybrid** | `/claude-orchestrator:implement-hybrid` | Compute the tier/batch schedule from the manifest, then drive one workflow invocation per batch. The skill stays the human gateway (clarifications, user-required actions); the workflow does the headless fan-out and fix rounds. |

### Review

| Skill | Command | Purpose |
|-------|---------|---------|
| **review-spec** | `/claude-orchestrator:review-spec` | Review phase specs before implementation. A workflow fans out one reviewer per phase and runs deterministic cross-phase checks in JS; the skill presents findings and applies approved fixes. |
| **review-orchestrated** | `/claude-orchestrator:review-orchestrated` | Review completed implementation against specs and rules. A workflow fans out one reviewer per phase; the skill applies an auto-fix ruleset, presents decisions, and applies fixes via a workflow. |

## Architecture

The skill is the **coordinator and human gateway**; the workflow is the **headless parallel engine**. A background workflow cannot pause to ask the user anything, so anything requiring a human — a spec clarification, a user-required real-world action, a review decision — is handled by the skill *between* workflow invocations. Everything that can run unattended — spawning implementers, verifying them, retrying failures, applying a pre-resolved fix list — runs inside the workflow.

```
implement-hybrid skill (main loop, human gateway)
  └─ per batch → Workflow(workflows/implement.mjs)
        ├─ parallel implementers (one per task_group)
        ├─ parallel wave-verifiers (one per ≤4 task_groups, phase-partitioned)
        └─ up to 2 headless fix rounds on FAIL

review-spec skill                review-orchestrated skill
  └─ Workflow(review-spec.mjs)     └─ Workflow(review.mjs)
        ├─ parallel spec reviewers      └─ parallel phase reviewers
        └─ JS cross-phase checks
  └─ Workflow(apply-fixes.mjs)     └─ Workflow(apply-fixes.mjs)
        └─ parallel fix-agents          └─ parallel fix-agents
```

There is **no state file, no spawn-gate hook, and no recording script.** Each agent returns a structured object validated against a JSON Schema (documented in `references/agent-output-schemas.md`); the workflow reads that object directly. Durable state lives where it always should: `git` commits, `spec/progress.md`, and the phase specs.

**Batches, tiers, and task_groups.** The `implement-hybrid` skill reads `spec/manifest.json` and computes the schedule from each phase's `depends_on`: phases are layered into **tiers** (siblings in a tier run concurrently), and within a tier the *k*-th wave of every phase is merged into one **batch**. A batch can span sibling phases; this is safe because `review-spec` guarantees sibling phases are file-disjoint. The skill passes one batch's task_groups to `workflows/implement.mjs`, which spawns one implementer per group, verifies the completed groups (one verifier per ≤4 groups, never mixing phases), and runs up to two fix rounds on any FAIL — all without human involvement. Only clarifications and user-required actions bubble back to the skill as blockers.

**File coordination.** Parallel implementers never touch the same file: the spec author and `review-spec` enforce that sibling phases — and the task_groups within them — are file-disjoint. No lock layer is needed.

## Agents

Agents are spawned by workflows via `agentType`, not invoked directly. Their definition files (`agents/*.md`) hold the audit/implementation logic; the only thing they record is their structured return.

| Agent | Spawned by | Role |
|-------|-----------|------|
| **implementer** | `workflows/implement.mjs` | Executes one task_group end-to-end, writes tests, self-continues, returns `IMPL_RESULT` (`complete` / `needs_clarification` / `user_action_required`). |
| **wave-verifier** | `workflows/implement.mjs` | Audits each task_group against its spec, scans for rule violations, runs the test suite vs the baseline, returns `VERIFY_RESULT` (PASS/FAIL per group). |
| **reviewer** | `workflows/review.mjs` | Audits a completed phase against specs, rules, and test quality; returns `REVIEW_RESULT`. |
| **review-spec** | `workflows/review-spec.mjs` | Audits one phase spec across seven dimensions; returns `SPEC_REVIEW_RESULT` plus the phase's Files Owned list. |
| **fix-agent** | `workflows/apply-fixes.mjs` | Applies a pre-resolved edit list to a fixed file set, optionally runs tests, returns `FIX_RESULT`. |

## Typical Workflow

```
1. Plan        /claude-orchestrator:plan-orchestrated "add user authentication"
2. Spec        /claude-orchestrator:plan-spec 1          (repeat per phase)
3. Review      /claude-orchestrator:review-spec          (optional, catches spec issues early)
4. Implement   /claude-orchestrator:implement-hybrid     (per-batch workflow + human gate)
5. Review      /claude-orchestrator:review-orchestrated  (catches rule violations, weak tests)
```

## Project Structure

```
claude-orchestrator/
  agents/                    # Agent instruction files (audit/implementation logic)
    implementer.md
    wave-verifier.md
    reviewer.md
    review-spec.md
    fix-agent.md
  workflows/                 # Deterministic orchestration scripts
    implement.mjs            # per-batch fan-out: implement → verify → fix rounds
    review.mjs               # per-phase post-implementation review fan-out
    review-spec.mjs          # per-phase spec review + JS cross-phase checks
    apply-fixes.mjs          # shared fix-agent fan-out for both review skills
  skills/                    # Skill definitions (SKILL.md per skill)
    plan-orchestrated/
    plan-spec/
    implement-hybrid/
    review-orchestrated/
    review-spec/
  references/                # Shared reference files
    rules.md                 # Non-negotiable implementation rules
    agent-output-schemas.md  # The structured-output contract between agents and workflows
  CLAUDE.md                  # Plugin-level rules and principles
```

## Spec Directory (Created Per Project)

When you run the plugin against a project, it creates a `spec/` directory:

```
your-project/
  spec/
    plan.md                  # High-level implementation plan (planning artifact — not a runtime input)
    phase-{n}-{name}.md      # Detailed spec per phase (task content)
    manifest.json            # Job-control manifest (task_groups, complexity, depends_on, user-required flags)
    progress.md              # Append-only implementation progress (durable cross-skill trail)
    test-baseline.md         # Pre-existing test state (scratch; removed at end of run)
    reviews/                 # Review reports (human-readable artifacts)
```

## Core Principles

1. **Specs are current-state contracts.** No decision history, no changelogs. Updated in place.
2. **All spec files are flat in `spec/`.** No nesting.
3. **Tests assert desired behaviour.** No `pytest.skip()`, no soft assertions, no loose tolerances.
4. **No deferred work.** No TODO/FIXME/HACK comments. No `pass` or `raise NotImplementedError`.
5. **No backwards compatibility shims.** No fallbacks, no commented-out code, no historical-provenance comments.
