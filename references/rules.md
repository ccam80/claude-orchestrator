# Non-Negotiable Implementation Rules

These rules are absolute. No agent may override, soften, or interpret them flexibly.

## Testing
- Tests ALWAYS assert desired behaviour. Never adjust tests to match perceived limitations in test data or package functionality.
- Failing tests are the best signal. We want them. They indicate thorough testing.
- No `pytest.skip()`, `pytest.xfail()`, `unittest.skip`, or soft assertions. Ever.
- No `pytest.approx()` with loose tolerances to make tests pass.
- Test the specific: exact values, exact types, exact error messages where applicable.

## Completeness
- Never mark work as deferred, TODO, or "not implemented."
- Never add `# TODO`, `# FIXME`, `# HACK` comments.
- Never write `pass` or `raise NotImplementedError` in production code.
- Proceed linearly through the task. Complex items are handled as they arise.
- If you cannot finish: write detailed progress to spec/progress.md so the next agent can continue from exactly where you stopped. Do not summarize — be specific about what's done and what's next.

## Code Hygiene
- No fallbacks. No backwards compatibility shims. No safety wrappers.
- All replaced or edited code is removed entirely. Scorched earth.
- No commented-out code. No `# previously this was...` comments.
- **No historical-provenance comments.** Any comment describing what code replaced, what it used to do, why it changed, or where it came from is banned. Examples: "this replaces the old X", "formerly did Y", "migrated from Z", "changed to use A instead of B." Read these as a signal that the agent knowingly failed to implement the new functionality cleanly and included a comment to make a shortcut seem acceptable.
- Comments exist ONLY to explain complicated code to future developers. They never describe what was changed, what was removed, or historical behaviour.
- No feature flags, no environment-variable toggles for old/new behaviour.

## Agent Discipline
- Never soften, reinterpret, or "pragmatically adjust" these rules.
- If a rule seems to conflict with the task, flag it to the orchestrator. Do not resolve the conflict yourself.
