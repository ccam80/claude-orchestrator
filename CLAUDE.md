# Claude Orchestrator

You are operating within the claude-orchestrator plugin. This plugin manages structured planning and parallel implementation of software features.

## Skills and Agents

### Skills (user-invocable)
- **plan-orchestrated** — generate a high-level implementation plan with phases, waves, and verification measures
- **plan-spec** — produce a detailed implementation spec for a single phase
- **review-spec** — review phase specs for quality, consistency, and implementability before implementation
- **implement-hybrid** — skill that drives a per-batch workflow (`workflows/implement.mjs`): the skill computes the tier/batch schedule and stays the human gateway; the workflow fans out implementers and wave-verifiers and runs headless fix rounds
- **review-orchestrated** — review completed implementation against specs and rules

### Agents (spawned by workflows)
- **implementer** — executes tasks as specified, writes tests, self-continues through its task_group, returns a structured `IMPL_RESULT`. Spawned by `workflows/implement.mjs`.
- **wave-verifier** — audits each batch for spec coverage, rule compliance, and test regressions; returns a structured `VERIFY_RESULT` (PASS/FAIL per task_group). Spawned by `workflows/implement.mjs`.
- **reviewer** — audits a completed phase against specs and rules, returns structured findings. Spawned by `workflows/review.mjs`.
- **review-spec** — audits a phase spec for coverage, consistency, completeness, concreteness, implementability, returns structured findings + Files Owned. Spawned by `workflows/review-spec.mjs`.
- **fix-agent** — applies a pre-resolved edit list to a fixed file set, returns a structured `FIX_RESULT`. Spawned by `workflows/apply-fixes.mjs`.

## Core Principles

1. **Specs are current-state contracts.** They contain ONLY what to build. No decision history, no changelogs, no "previously we considered X." If a decision changes, the spec is updated in place — replaced, not appended.

2. **All spec files are flat in `spec/`.** No nesting, no subdirectories for specs. This is a hard constraint.

3. **Read project CLAUDE.md first.** Before any planning or implementation work, read the target project's CLAUDE.md for project-specific rules and conventions.

4. **Read existing specs before creating new ones.** Always check what already exists in `spec/` to avoid contradictions or duplication.

## Non-Negotiable Rules

These rules apply to ALL sessions — planning, speccing, and implementation.

### Testing
- Tests ALWAYS assert desired behaviour. Never adjust tests to match perceived limitations.
- No `pytest.skip()`, `pytest.xfail()`, `unittest.skip`, or soft assertions. Ever.
- No `pytest.approx()` with loose tolerances to make tests pass.

### Completeness
- Never mark work as deferred, TODO, or "not implemented."
- Never add `# TODO`, `# FIXME`, `# HACK` comments.
- Never write `pass` or `raise NotImplementedError` in production code.

### Code Hygiene
- No fallbacks. No backwards compatibility shims. No safety wrappers.
- All replaced or edited code is removed entirely.
- No commented-out code. No `# previously this was...` comments.
- **Historical-provenance comments are dead-code markers, not comment problems.** Comments containing "legacy", "fallback", "backwards compatible", "previously", "migrated from", "replaced", "shim", "workaround", or "temporary" signal that an agent left dead or transitional code in place to avoid deleting it and fixing broken tests. The fix is to delete the decorated code AND the comment, then fix any tests that relied on the dead code path. Removing only the comment is a violation.
- Comments exist ONLY to explain complicated code to future developers.

### User-Required Tasks
- Tasks whose spec explicitly requires the user are **hard stop gates**. No task can pass verification with any form of deferral on a user-required action without explicit user permission through the orchestrator.
- Implementers must return `user_action_required` for user-required tasks — they cannot mark them complete.
- The implement-hybrid skill must surface user-required tasks immediately via `AskUserQuestion` and not advance the group until the user confirms completion.
- Verifiers and reviewers must FAIL any task_group where a user-required action was deferred, stubbed, or placeholdered.

### Agent Discipline
- Never soften, reinterpret, or "pragmatically adjust" these rules.
- If a rule seems to conflict with the task, flag it to the user or orchestrator. Do not resolve the conflict yourself.
