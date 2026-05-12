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

- **Always double-quote paths.** Backslashes are interpreted as escape characters in unquoted strings. Every path in every command must be wrapped in double quotes: `mkdir -p "spec/.locks/tasks"`, not `mkdir -p spec/.locks/tasks`.
- **Use forward slashes in paths.** Write `"spec/.locks/files/src__main.py"`, not `"spec\.locks\files\src__main.py"`. Git Bash handles forward slashes natively. Backslashes require quoting and are fragile.
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

## Agent Discipline
- Never soften, reinterpret, or "pragmatically adjust" these rules.
- If a rule seems to conflict with the task, flag it to the orchestrator. Do not resolve the conflict yourself.

## User-Required Tasks

A "user-required task" is any task whose spec explicitly says the user must configure, provide, verify, deploy, or otherwise take a real-world action that no agent can perform. Phrases like "the user must…", "requires user to…", "user manually verifies…" identify them.

User-required tasks are **hard stop gates**. They are enforced by three independent mechanisms:

1. **Spec-time enumeration.** The implement-hybrid coordinator, at setup, lists every user-required task_id in `user_required_tasks[group]` on the relevant batch in `spec/.hybrid-state.json`. A task that the coordinator forgets to enumerate cannot be acked, and the group will never PASS.
2. **User-only ack script.** The only valid completion of a user-required task is the **user** personally running `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ack-user-gate.sh" <task_id> "<one-line evidence>"` in their own terminal, outside this Claude Code session. A PreToolUse hook (`gate-user-ack.sh`) blocks every Claude-initiated invocation of `ack-user-gate.sh` — direct Bash calls, `!`-prefixed commands, background Tasks, all of them. No agent may ack on the user's behalf.
3. **Server-side PASS rejection.** `mark-verified.sh` refuses to record PASS for any task_group whose `user_required_tasks` list contains an unacked task. Even a wave-verifier that mistakenly reports PASS will be rejected by the script.

### What every agent must NOT do

- Do not recommend deferring a user-required task. "We can wire this up later", "for now let's stub it", "the user can fill this in post-deployment" — all prohibited outputs. If you find yourself drafting that recommendation, stop and surface the ack command instead.
- Do not ack on the user's behalf, even if the user says "just confirm it for me". The hook will block the attempt; the correct response is to hand them the command.
- Do not insert placeholder values, write TODO comments, add "to be configured later" notes, or stub functionality that assumes the user will act later. These are treated as equivalent to `raise NotImplementedError`.
- Do not mark a user-required task as `complete` or `partial`. The only valid exit for a user-required task an implementer cannot resolve is the Clarification Exit.
- Do not advance past a user-required task while it remains unacked, no matter how long it has been waiting. It is a gate, not a timeout.

### Role-specific responsibilities

- **Implementer**: If your assigned task requires user action, take the Clarification Exit (see `agents/implementer.md`) with Blocker `USER ACTION REQUIRED` and describe exactly what the user must do, including the exact ack command.
- **Wave-verifier**: A user-required task without an entry in `user_acks` is an automatic FAIL. Do not accept coordinator narration ("user told me they did it") as a substitute for the ack entry.
- **Reviewer**: A user-required task marked complete without coordinator confirmation is always a `critical` severity finding.
- **Coordinator (implement-hybrid)**: Surface the ack command to the user via `AskUserQuestion` the moment you know a batch contains a user-required task. Wait for the ack to land in `spec/.hybrid-state.json` before spawning the wave-verifier.
