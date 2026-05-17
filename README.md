# Claude Orchestrator

A Claude Code plugin for structured planning and parallel implementation of software features. Breaks large features into phased plans, detailed specs, and parallel implementation waves with automated review.

## Skills (User-Invocable Commands)

The plugin provides five skills, organized into three workflows:

### Planning

| Skill | Command | Purpose |
|-------|---------|---------|
| **plan-orchestrated** | `/claude-orchestrator:plan-orchestrated` | Generate a high-level implementation plan with phases, waves, and verification measures. Collaboratively define goals, scope, and task structure with the user. |
| **plan-spec** | `/claude-orchestrator:plan-spec` | Take a phase from the plan and produce a detailed implementation spec. Every design decision goes through the user. |

### Implementation

| Skill | Command | Purpose |
|-------|---------|---------|
| **implement-hybrid** | `/claude-orchestrator:implement-hybrid` | Coordinator spawns implementers directly, then spawns a wave-verifier after each batch. Two-level architecture with state-file coordination (`spec/.hybrid-state.json`), PreToolUse spawn gates, and in-band recording scripts run by the subagents themselves. |

### Review

| Skill | Command | Purpose |
|-------|---------|---------|
| **review-spec** | `/claude-orchestrator:review-spec` | Review phase specs for quality, consistency, and implementability before implementation. Spawns parallel review agents per phase with cross-phase checks. |
| **review-orchestrated** | `/claude-orchestrator:review-orchestrated` | Review completed implementation against specs and rules. Spawns reviewer agents per phase, presents findings, then fixes mechanical violations with user approval. |

## Agents

Agents are spawned by skills — you don't invoke them directly. Each agent has a focused role:

| Agent | Used By | Role |
|-------|---------|------|
| **implementer** | implement-hybrid | Executes implementation tasks exactly as specified, writes tests, self-continues to next available task. Uses file-level locking for parallel coordination. Calls `complete-implementer.sh` (or `stop-for-clarification.sh`) as its final bash call to record state. |
| **wave-verifier** | implement-hybrid | After each batch completes, audits every spec element against implementation, scans for rule violations, and runs the test suite against the pre-batch baseline. Emits a `PASS`/`FAIL` verdict per task_group and records it via `mark-verified.sh`. The coordinator's spawn gate blocks the next batch until every task_group has `group_status == "passed"`. |
| **reviewer** | review-orchestrated | Audits a completed phase against specs, rules, and code quality standards. Investigates and reports — never fixes. |
| **review-spec** | review-spec | Audits a single phase spec for plan coverage, internal consistency, completeness, concreteness, and implementability. |

## Typical Workflow

```
1. Plan        /claude-orchestrator:plan-orchestrated "add user authentication"
2. Spec        /claude-orchestrator:plan-spec 1          (repeat per phase)
3. Review      /claude-orchestrator:review-spec          (optional, catches spec issues early)
4. Implement   /claude-orchestrator:implement-hybrid     (per-batch wave-verifier gate)
5. Review      /claude-orchestrator:review-orchestrated  (catches rule violations, weak tests)
```

## Implementation Architecture

`implement-hybrid` is a two-level orchestration model:

```
coordinator (the skill instance)
  ├─ implementers (one per task_group, background Tasks)
  └─ wave-verifier (one per batch, after implementers complete)
```

**Batches and task_groups.** The coordinator reads `spec/manifest.json` — the job-control artifact written by `plan-spec` — and translates it into batches: one wave becomes one batch, in manifest order. Task_groups are defined in the manifest (one task_group per implementer); the coordinator copies them verbatim and never re-clusters tasks. It does not read `spec/plan.md` or the phase spec files — those are read by the implementers and verifiers it spawns.

**State file (`spec/.hybrid-state.json`).** Written once by the coordinator at setup, then updated exclusively by scripts invoked by the subagents themselves. Combines per-batch counters with a `group_status` map (`pending`/`failed`/`passed`) per task_group. Persists across context compressions — if the coordinator is resumed mid-run, it re-reads the state file and picks up on the first batch whose `group_status` has any entry that is not `"passed"`.

**Spawn gates.** Two PreToolUse hooks enforce the workflow at the Claude Code runtime level:
- `gate-implementer.sh` — allows an implementer spawn iff slot cap not exceeded and all completed work has been reviewed.
- `gate-verifier.sh` — allows a wave-verifier spawn iff unreviewed completed work exists and the batch is not fully verified.

The coordinator cannot work around a block by editing the state file; the hooks read it every time.

**In-band recording scripts.** Ownership of every state field is fixed:

| Field | Writer | Trigger |
|-------|--------|---------|
| `spawned` | `gate-implementer.sh` | PreToolUse on Agent |
| `completed` | `complete-implementer.sh` | Implementer's final bash call (normal finish) |
| `stops_for_clarification` | `stop-for-clarification.sh` | Implementer's final bash call (clarification exit) |
| `verifications_passed` / `verifications_failed` / `group_status` | `mark-verified.sh` | Wave-verifier's final bash call with a JSON verdict map |
| `dead_implementers` / `dead_verifiers` | `mark-dead-implementer.sh` / `mark-dead-verifier.sh` | Coordinator invokes under the dead-subagent fallback |

See `skills/implement-hybrid/SKILL.md` for the full protocol including the dead-subagent fallback, clarification exits, and spawn condition formulas.

## Project Structure

```
claude-orchestrator/
  agents/                    # Agent instruction files
    implementer.md
    wave-verifier.md
    reviewer.md
    review-spec.md
  skills/                    # Skill definitions (SKILL.md per skill)
    implement-hybrid/
    plan-orchestrated/
    plan-spec/
    review-orchestrated/
    review-spec/
  references/                # Shared reference files
    handoff-templates.md     # Prompt templates for agent handoffs
    lock-protocol.md         # File/task locking for parallel agents
    rules.md                 # Non-negotiable implementation rules
  scripts/
    materialize-context.sh   # Copies context files to spec/.context/
    gate-implementer.sh      # PreToolUse gate for implementer spawns
    gate-verifier.sh         # PreToolUse gate for wave-verifier spawns
    complete-implementer.sh  # Implementer's final bash call (normal finish)
    stop-for-clarification.sh # Implementer's final bash call (clarification exit)
    mark-verified.sh         # Wave-verifier's final bash call (verdict map)
    mark-dead-implementer.sh # Coordinator's dead-subagent fallback (implementer)
    mark-dead-verifier.sh    # Coordinator's dead-subagent fallback (verifier)
  CLAUDE.md                  # Plugin-level rules and principles
```

## Spec Directory (Created Per Project)

When you run the plugin against a project, it creates a `spec/` directory:

```
your-project/
  spec/
    plan.md                  # High-level implementation plan (architecture/planning — not a runtime input)
    phase-{n}-{name}.md      # Detailed spec per phase (task content)
    manifest.json            # Job-control manifest (task_groups, complexity, user-required flags) — consumed by implement-hybrid
    progress.md              # Append-only implementation progress
    test-baseline.md         # Pre-existing test state
    reviews/                 # Review reports (phase-level)
    .context/                # Materialized agent files (gitignore this)
    .locks/                  # Runtime lock files (gitignore this)
    .hybrid-state.json       # Coordinator state for implement-hybrid (gitignore this)
```

## Core Principles

1. **Specs are current-state contracts.** No decision history, no changelogs. Updated in place.
2. **All spec files are flat in `spec/`.** No nesting.
3. **Tests assert desired behaviour.** No `pytest.skip()`, no soft assertions, no loose tolerances.
4. **No deferred work.** No TODO/FIXME/HACK comments. No `pass` or `raise NotImplementedError`.
5. **No backwards compatibility shims.** No fallbacks, no commented-out code, no historical-provenance comments.
