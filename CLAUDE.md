# Claude Orchestrator

You are operating within the claude-orchestrator plugin. This plugin manages structured planning and parallel implementation of software features.

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
- Comments exist ONLY to explain complicated code to future developers.

### Agent Discipline
- Never soften, reinterpret, or "pragmatically adjust" these rules.
- If a rule seems to conflict with the task, flag it to the user or orchestrator. Do not resolve the conflict yourself.
