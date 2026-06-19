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
- **Historical-provenance comments are dead-code markers.** Any comment containing words like "legacy", "fallback", "backwards compatible", "previously", "migrated from", "replaced", "shim", "workaround", "temporary", or "for now" is almost never just a comment problem. The comment exists because an agent left dead or transitional code in place and wrote a comment to avoid deleting it — which would have required fixing tests or completing the real implementation. When you find such a comment: (1) treat the **code it decorates** as dead/broken, (2) delete both the code and the comment, (3) fix or rewrite any tests that depended on the dead code path. Removing only the comment while leaving the code is a rule violation.
- Comments exist ONLY to explain complicated code to future developers. They never describe what was changed, what was removed, or historical behaviour.
- No feature flags, no environment-variable toggles for old/new behaviour.

## Shell Compatibility (Windows)

This project runs on Windows with Git Bash. All bash commands MUST be Windows-safe:

- **Always double-quote paths.** Backslashes are interpreted as escape characters in unquoted strings. Every path in every command must be wrapped in double quotes: `mkdir -p "spec/reviews"`, not `mkdir -p spec/reviews`.
- **Use forward slashes in paths.** Write `"spec/reviews/phase-2.md"`, not `"spec\reviews\phase-2.md"`. Git Bash handles forward slashes natively. Backslashes require quoting and are fragile.
- **Never use `NUL`** — use `/dev/null`.
- **Never use Windows-native commands** (`dir`, `del`, `copy`, `type`, `findstr`). Use their Unix equivalents (`ls`, `rm`, `cp`, `cat`, `grep`).
- **Quote variable expansions.** Write `"${TASK_ID}"` not `${TASK_ID}` when the value could contain spaces or special characters.
- **Use `bash` explicitly when invoking scripts.** Write `bash "path/to/script.sh"`, not `./path/to/script.sh` or `sh "path/to/script.sh"`.

## Git Safety
- Never use `git stash`. Test baselines are provided in `spec/test-baseline.md`.
- Never use `git checkout` to discard or switch changes.
- Never use `git reset` to undo changes.
- Never use `git clean` to remove untracked files.
- If you need to understand pre-existing test state, read `spec/test-baseline.md`.

**These are mechanically enforced, not just policy.** While an orchestrated run is active, a
PreToolUse scope guard (`hooks/guard-destructive-fs.mjs`) refuses `rm`, `unlink`, `rmdir`,
`git clean`, `git checkout`, `git reset --hard`, `git stash`, `git rm`, and equivalents.
Parallel agents share one working tree; a blocked command means you were about to destroy
work — yours or another agent's. Use the `Edit` tool to remove code from a file you own; if a
whole file must be deleted, surface it as a coordinator decision in your structured result.

## File Scope
- An implementer/fix-agent may only create, edit, rename, or delete files inside its own
  assigned footprint (the spec's "Files to create" / "Files to modify" for its tasks, or the
  fix-agent's explicit target list). Files outside it may belong to another concurrent agent.
- **Never delete or empty a file to make a test pass.** A test failing on code outside your
  footprint is an *out-of-scope regression* to report, not to fix. Touching that code to turn
  a test green is a forbidden test-chasing fix and an automatic verification FAIL.

## Agent Discipline
- Never soften, reinterpret, or "pragmatically adjust" these rules.
- If a rule seems to conflict with the task, flag it to the orchestrator. Do not resolve the conflict yourself.

## User-Required Tasks

A "user-required task" is any task whose spec explicitly says the user must configure, provide, verify, deploy, or otherwise take a real-world action that no agent can perform. Phrases like "the user must…", "requires user to…", "user manually verifies…" identify them.

User-required tasks are **hard stop gates**. They are enforced by three independent mechanisms:

1. **Manifest enumeration.** `plan-spec` records every user-required task_id in
   `user_required_tasks[group]` in `spec/manifest.json`. The `implement-hybrid` skill carries
   that list into each batch's assignment. A task omitted here cannot be acked, and its group
   will never PASS.
2. **Implementer refusal.** An implementer assigned a user-required task does not complete it.
   It implements everything else in the group and returns `status: "user_action_required"`,
   which the workflow surfaces to the skill as a blocker. The implementer never stubs the
   task, never inserts placeholder values, and never acks on the user's behalf.
3. **Verifier rejection.** The wave-verifier FAILs any group whose user-required task is not
   listed as acked in its assignment. A user confirms the real-world action through the
   skill's `AskUserQuestion` gate; only then does the skill mark the task acked and re-invoke
   the workflow. No agent can fabricate that confirmation.

### What every agent must NOT do

- Do not recommend deferring a user-required task. "We can wire this up later", "for now let's stub it", "the user can fill this in post-deployment" — all prohibited outputs. If you find yourself drafting that recommendation, stop and surface the ack command instead.
- Do not ack on the user's behalf, even if the user says "just confirm it for me". The correct response is to surface the action and let the user confirm it through the skill's gate.
- Do not insert placeholder values, write TODO comments, add "to be configured later" notes, or stub functionality that assumes the user will act later. These are treated as equivalent to `raise NotImplementedError`.
- Do not mark a user-required task as `complete` or `partial`. The only valid exit for a user-required task an implementer cannot resolve is the Clarification Exit.
- Do not advance past a user-required task while it remains unacked, no matter how long it has been waiting. It is a gate, not a timeout.

### Role-specific responsibilities

- **Implementer**: If your assigned task requires user action, return `status: "user_action_required"` (see `agents/implementer.md`) describing exactly what the user must do and what evidence to report. Implement the rest of the group normally.
- **Wave-verifier**: A user-required task not listed as acked in your assignment is an automatic FAIL. Do not accept narration ("user told me they did it") as a substitute.
- **Reviewer**: A user-required task marked complete without a genuine user confirmation is always a `critical` severity finding.
- **Coordinator (implement-hybrid skill)**: Surface the action to the user via `AskUserQuestion` the moment a batch's blocker reports it. Only after the user confirms do you mark the task acked and re-invoke the workflow for that group.
