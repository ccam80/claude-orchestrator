# Claude Orchestrator

A Claude Code plugin for structured planning and parallel implementation of software features. Breaks large features into phased plans, detailed specs, and parallel implementation waves with automated review.

## Skills (User-Invocable Commands)

The plugin provides six skills, organized into three workflows:

### Planning

| Skill | Command | Purpose |
|-------|---------|---------|
| **plan-orchestrated** | `/claude-orchestrator:plan-orchestrated` | Generate a high-level implementation plan with phases, waves, and verification measures. Collaboratively define goals, scope, and task structure with the user. |
| **plan-spec** | `/claude-orchestrator:plan-spec` | Take a phase from the plan and produce a detailed implementation spec. Every design decision goes through the user. |

### Implementation

| Skill | Command | Purpose |
|-------|---------|---------|
| **implement-hybrid** | `/claude-orchestrator:implement-hybrid` | Spawn implementers directly with state-based coordination. Two-level architecture (coordinator → implementers) for ~40-60% better context efficiency. **Recommended if you have [oh-my-claudecode](https://github.com/nicobailon/oh-my-claudecode) installed.** |
| **implement-orchestrated** | `/claude-orchestrator:implement-orchestrated` | Spawn orchestrator and implementer agents in a three-level architecture (coordinator → orchestrator → implementers). Works without oh-my-claudecode. |

### Review

| Skill | Command | Purpose |
|-------|---------|---------|
| **review-spec** | `/claude-orchestrator:review-spec` | Review phase specs for quality, consistency, and implementability before implementation. Spawns parallel review agents per phase with cross-phase checks. |
| **review-orchestrated** | `/claude-orchestrator:review-orchestrated` | Review completed implementation against specs and rules. Spawns reviewer agents per phase, presents findings, then fixes mechanical violations with user approval. |

## Agents

Agents are spawned by skills — you don't invoke them directly. Each agent has a focused role:

| Agent | Used By | Role |
|-------|---------|------|
| **implementer** | implement-hybrid, implement-orchestrated | Executes implementation tasks exactly as specified, writes tests, self-continues to next available task. Uses file-level locking for parallel coordination. |
| **orchestrator** | implement-orchestrated | Manages a single wave of implementation tasks by spawning and monitoring implementer agents. Eliminated in implement-hybrid for better context efficiency. |
| **reviewer** | implement-hybrid, implement-orchestrated, review-orchestrated | Audits implementation output against specs, rules, and quality standards. Investigates and reports — never fixes. |
| **review-spec** | review-spec | Audits a single phase spec for plan coverage, internal consistency, completeness, concreteness, and implementability. |

## Typical Workflow

```
1. Plan        /claude-orchestrator:plan-orchestrated "add user authentication"
2. Spec        /claude-orchestrator:plan-spec 1          (repeat per phase)
3. Review      /claude-orchestrator:review-spec          (optional, catches spec issues early)
4. Implement   /claude-orchestrator:implement-hybrid     (or implement-orchestrated)
5. Review      /claude-orchestrator:review-orchestrated   (catches rule violations, weak tests)
```

## implement-hybrid vs implement-orchestrated

| Aspect | implement-hybrid | implement-orchestrated |
|--------|-----------------|----------------------|
| Architecture | 2-level (coordinator → implementers) | 3-level (coordinator → orchestrator → implementers) |
| Context efficiency | ~40-60% better | Baseline |
| Recovery | State file (`spec/.hybrid-state.json`) enables mid-run resume | Relies on `spec/progress.md` |
| Dependency | Works best with oh-my-claudecode | Works standalone |
| Materialized files | 3 (rules, lock-protocol, reviewer) | 5 (+ orchestrator, implementer) |

**Use implement-hybrid** if you have oh-my-claudecode installed. It eliminates the orchestrator middle layer, saving ~4,700 tokens of agent file reads and ~1,500 tokens of monitoring context per implementer round.

**Use implement-orchestrated** if you're running vanilla Claude Code without oh-my-claudecode.

## Project Structure

```
claude-orchestrator/
  agents/                    # Agent instruction files
    implementer.md
    orchestrator.md
    reviewer.md
    review-spec.md
  skills/                    # Skill definitions (SKILL.md per skill)
    implement-hybrid/
    implement-orchestrated/
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
  CLAUDE.md                  # Plugin-level rules and principles
```

## Spec Directory (Created Per Project)

When you run the plugin against a project, it creates a `spec/` directory:

```
your-project/
  spec/
    plan.md                  # High-level implementation plan
    phase-{n}-{name}.md      # Detailed spec per phase
    progress.md              # Append-only implementation progress
    test-baseline.md         # Pre-existing test state
    reviews/                 # Review reports (wave and phase level)
    .context/                # Materialized agent files (gitignore this)
    .locks/                  # Runtime lock files (gitignore this)
    .hybrid-state.json       # Recovery state for implement-hybrid
```

## Core Principles

1. **Specs are current-state contracts.** No decision history, no changelogs. Updated in place.
2. **All spec files are flat in `spec/`.** No nesting.
3. **Tests assert desired behaviour.** No `pytest.skip()`, no soft assertions, no loose tolerances.
4. **No deferred work.** No TODO/FIXME/HACK comments. No `pass` or `raise NotImplementedError`.
5. **No backwards compatibility shims.** No fallbacks, no commented-out code, no historical-provenance comments.
