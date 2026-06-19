---
name: review-orchestrated
description: Review completed implementation against specs and rules. Drives a workflow that fans out one reviewer per phase, applies an internal auto-fix ruleset, presents only true decisions to the user, then applies fixes via a workflow.
argument-hint: <phase name or number, or blank for all completed phases>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Workflow]
---

# Review Orchestrated

You are the review coordinator and human gateway. A workflow does the headless fan-out
(one reviewer per phase) and returns structured findings; you apply the auto-fix ruleset,
present the single-pass output, collect decisions, and drive a second workflow to apply the
fixes. There is no `spec/.context/` materialization and no markdown-report parsing — the
reviewer's structured return is the channel.

## Setup

1. Determine the project root and resolve the plugin root (`${CLAUDE_PLUGIN_ROOT}`).
2. Read `spec/progress.md` to find which phases have completed tasks. Each such phase is one
   review unit. Read `spec/manifest.json` for each phase's `spec_file` and `name`.
3. If `$ARGUMENTS` names a phase, limit scope to it; otherwise review all phases with
   completed work.

## Review

Invoke the review workflow:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/review.mjs",
  args: { project_dir, plugin_root, phases: [{ phase, name, spec_file }] }
})
```

It returns `{ perPhase: [{ phase, verdict, findings: [{ id, category, severity, file, line, rule, evidence, fix_hint }] }] }`.
Each reviewer also wrote a full human-readable report to `spec/reviews/phase-{n}.md`.

If every phase is `clean` → report "All clean" and stop.

## Apply the Auto-Fix Ruleset

For each finding ask: "does this require a decision from the user?" If it matches a rule
below, there is exactly one correct fix — queue it, do not ask.

**Auto-fix (no decision required):**

| Pattern (category / fix_hint) | Correct fix |
|---|---|
| Gap / missing implementation / `pass` / `raise NotImplementedError` / partial / scope-narrowed | Complete the task to spec exactly as written. |
| Weak test assertion (`is not None`, bare `isinstance`, `len(x) > 0`, trivially-true, loose `approx`, unspec'd mocks) | Rewrite the assertion to verify the desired behaviour AND report what it was hiding. |
| Historical-provenance / legacy / fallback comment | Read the spec for the decorated code. Compliant → delete just the comment. Not compliant → delete comment AND code, fix collateral tests. |
| `# TODO` / `# FIXME` / `# HACK` | Remove; if it marked unfinished work, complete the work to spec. |
| Commented-out code | Remove. |
| `pytest.skip()` / `xfail` / `unittest.skip` / soft asserts | Remove the decorator; if the test then fails, fix the bug it hid. |
| Dead imports | Remove. |
| Backwards-compat re-exports / deprecated wrappers / old-vs-new feature flags | Remove. |

**Decision required:** anything else — a behavioural choice with multiple valid
implementations, an ambiguous spec passage, or a finding the reviewer flagged for the user.

## Single-Pass Output

Emit ONE message. Do NOT use `AskUserQuestion`. Do NOT split turns. Do NOT ask approval for
auto-fixes — they are already queued.

```
## Auto-fixes queued (no decision required)
- {file:line} — {one-line description of the fix}

## Decisions needed
**D1 — {short title}** ({severity})
{1–2 lines: what the spec requires, what's there, what the user must choose.}
  A) {concrete fix — one line}
  B) {concrete fix — one line}
```

Full evidence stays in `spec/reviews/phase-{n}.md`. If there are no decision items, say
"No decisions needed — auto-fixes will be applied." and proceed without waiting.

## Collect Decisions (only if any exist)

The user replies in chat (e.g. "D1: B, D2: custom — {instruction}"). For `custom`, take
their free-text as the fix directive verbatim. Do not proceed until every decision item is
answered.

## Apply Fixes

Consolidate all queued fixes (auto-fixes + resolved decisions) into clusters grouped by
target file (or logically-related file cluster for cross-file fixes).

When there are **2 or more clusters**, the fix-agents run in parallel in one working tree, so
bracket the workflow with the same scope guard the implement skill uses — checkpoint first,
arm the guard, audit after:

```bash
git add -A && git commit -m "co: checkpoint before apply-fixes" --allow-empty -q
CHECKPOINT=$(git rev-parse HEAD)
mkdir -p .omc/state && printf 'active' > .omc/state/co-guard-active   # only when >=2 clusters
```

Invoke:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/apply-fixes.mjs",
  args: {
    project_dir, plugin_root,
    test_command,                       // from the manifest
    baseline_file: "spec/test-baseline.md",
    clusters: [{
      targets: [filePath],
      run_tests: true,
      edits: [{ id, source, file, old_string?, new_string?, directive?, report_hint? }]
    }]
  }
})
```

Label each edit `auto-fix:{rule}` or `user-decision:{id}` in its `source`. For weak-test
auto-fixes set `report_hint` to "report what the weak assertion was hiding"; for
legacy/fallback-comment auto-fixes set it to "verify the decorated code against the spec;
delete the comment if compliant, delete both code and comment if not, fix collateral tests."

The workflow returns `{ reports, mismatches }`. Reissue any `mismatches` with corrected
targets/old_strings.

If you armed the guard, disarm and audit immediately — build a footprint whose `modified`
list is the union of every cluster's `targets`, then:

```bash
rm -f .omc/state/co-guard-active
# /tmp/co-footprint.json = { "fixes": { "created": [], "modified": [<all cluster targets>] } }
node "${CLAUDE_PLUGIN_ROOT}/scripts/scope-audit.mjs" \
  --checkpoint "$CHECKPOINT" --footprint /tmp/co-footprint.json --apply
```

Surface any violation it reports (a fix-agent that edited or deleted a file outside its
assigned `targets`): deletions are restored from the checkpoint; an out-of-scope modification
or an unrecoverable loss (exit 2) is a STOP-and-report. Always `rm -f
.omc/state/co-guard-active` before finishing, including on any early exit.

## Verify and Report

1. The fix workflow ran tests per cluster. If all pass → report success. If any fail,
   present the failures alongside the fix reports — they may be a removed load-bearing line,
   a regression, a pre-existing failure, or a strengthened test now correctly catching a
   real bug (fix the bug, not the test). Do **not** unilaterally revert; ask the user.
2. Final summary: phases reviewed, total findings, auto-fixes applied (with weak-test
   discovery notes), decision fixes applied/skipped, any scope mismatches, test results.

## Important

- You never spawn agents or edit implementation files yourself — the workflows do. Your job
  is auto-fix classification, single-pass presentation, collecting decision replies, driving
  the fix workflow, and reporting.
- Never queue a decision-required fix without the user's pick. Auto-fixes never wait for
  approval; the auto-fix list is informational.
- Do not re-review after fixes — trust the fix reports plus the test run.

## Shell Safety (Windows)

Git Bash on Windows: double-quote paths, forward slashes, `/dev/null` not `NUL`, Unix commands.
