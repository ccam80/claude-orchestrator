---
name: review-spec
description: Review phase specs for quality, consistency, and implementability before implementation. Drives a workflow that fans out one reviewer per phase and runs deterministic cross-phase checks in JS, then applies approved fixes via a workflow.
argument-hint: <phase number(s), or blank for all>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Workflow]
---

# Review Spec

You are the spec-review coordinator and human gateway. A workflow fans out one review-spec
agent per phase, runs the deterministic cross-phase checks in plain JS (tier computation,
`depends_on` integrity, sibling file-disjointness, complexity/user-required validity), and
runs a single semantic cross-phase agent for the two checks that need judgement (duplicate
work, dependency compatibility). You present the consolidated findings, collect approvals
and decisions in one batch, then drive a fix workflow.

## Setup

1. Determine the project root and resolve the plugin root (`${CLAUDE_PLUGIN_ROOT}`).
2. Read `spec/manifest.json` and `spec/plan.md` enough to list the phases in scope (number,
   name, `spec_file`). If `$ARGUMENTS` names phase(s), limit to those; else all phases.

## Review + Cross-Phase

Invoke the workflow, passing the parsed manifest so the JS checks have their data:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/review-spec.mjs",
  args: { project_dir, plugin_root, manifest: <parsed spec/manifest.json>, phases: [{ phase, name, spec_file }] }
})
```

It returns:

```jsonc
{
  perPhase:  [{ phase, verdict, findings: [{ id, severity, classification, location, problem, proposed_fix, options }], files_owned }],
  crossPhase:[{ id, severity, classification, location, problem, proposed_fix, options }],   // X-* ids
  tiers:     { "0": [0], "1": [1], "2": [2,3] }
}
```

Each review-spec agent also wrote a full report to `spec/reviews/spec-phase-{n}.md`.

The deterministic cross-phase checks (tiers, `depends_on` cycles/forward-refs, sibling
shared files, complexity enum, user-required id validity, empty `test_command`,
exempt-phase-solo-tier) are already computed in JS and arrive as `crossPhase` findings —
you do not re-run them by hand.

## Consolidate

- **Deduplicate**: merge per-phase findings that describe the same underlying issue.
- **Promote on conflict**: a `minor` finding that conflicts with another phase becomes at
  least `major`.
- **Stable IDs**: per-phase `P{phase}-M{n}` / `P{phase}-D{n}`; cross-phase keep their `X-*`
  ids. Treat `classification: mechanical` as Mechanical and `decision-required` as Decision.

Overall verdict is `ready` if no `critical`/`major` remain after fixes are chosen, else
`needs-revision`.

## Present Findings (one pass, then one batched question)

1. Show the **Mechanical Fixes** table (ID, severity, location, problem, proposed fix) — all
   per-phase + cross-phase mechanical findings.
2. For each **Decision-Required** item, show the compact form:

```
**{ID} — {short title}** ({severity})
{1–3 lines: the problem and why it needs a decision.}
Options:
  A) {concrete fix — one line}
  B) {concrete fix — one line}
```

3. Issue a single `AskUserQuestion` containing:
   - "Approve Mechanical fixes?" → `all` / `subset (list IDs)` / `none`
   - one question per Decision-Required item → `A` / `B` / `C` / `skip` / `custom`

Do not proceed until the mechanical-approval answer and every decision item are answered.
For `custom`, take the free-text instruction as the fix directive verbatim.

## Apply Fixes

Group approved fixes by spec file. Invoke:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/apply-fixes.mjs",
  args: {
    project_dir, plugin_root,
    clusters: [{
      targets: ["spec/phase-{n}-{name}.md"],
      run_tests: false,
      edits: [{ id, source, file, old_string?, new_string?, directive? }]
    }]
  }
})
```

Label mechanical edits `mechanical:{id}` with verbatim before/after text from `proposed_fix`;
label decision edits `user-decision:{id}` with the chosen option (or custom text) as the
directive. Spec files have no tests, so `run_tests` is false. Reissue any `mismatches`.

## Final Summary

- Mechanical fixes applied / skipped (by phase)
- Decision items resolved / skipped (by phase)
- Edits the fix workflow could not apply (scope mismatches), with reason
- Whether the verdict is now `ready` or still `needs-revision`

## Important

- You never review specs or edit spec files yourself — the workflow's agents do the review,
  the fix workflow's agents apply edits. You consolidate, present, collect answers, drive.
- Never queue a decision-required fix without the user's pick. "Probably A" is not approval.
- The deterministic cross-phase checks are authoritative and free — never duplicate them by
  hand or second-guess their tier math.

## Shell Safety (Windows)

Git Bash on Windows: double-quote paths, forward slashes, `/dev/null` not `NUL`, Unix commands.
