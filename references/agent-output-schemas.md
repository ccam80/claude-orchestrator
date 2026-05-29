# Agent Output Schemas

Under the workflow-driven runtime, agents do **not** record state by calling shell
scripts and do **not** hand-write markdown reports as their control-flow channel.
Each agent returns a single **structured object** validated against a JSON Schema by
the workflow's `StructuredOutput` tool. The workflow script reads that object directly
— no parsing, no state file, no recording scripts.

A human-readable artifact (e.g. `spec/reviews/phase-{n}.md`) MAY still be written to
disk for the user's audit trail, but it is never the channel the orchestrator reads.

These schemas are the contract between each agent and the workflow that spawns it.
The workflow scripts in `workflows/` embed the authoritative JSON Schema; this file is
the human-readable reference.

## implementer → `IMPL_RESULT`

```jsonc
{
  "group_id": "2.1.a",
  "status": "complete | needs_clarification | user_action_required",
  "files_created": ["src/foo.py"],
  "files_modified": ["src/bar.py"],
  "tasks": [{ "id": "T2.1.1", "status": "complete | not_started" }],

  // present only when status == needs_clarification
  "clarification": {
    "task_id": "T2.1.2",
    "summary": "one-line ambiguity",
    "spec_quote": "the ambiguous spec text, verbatim, with its heading",
    "readings": ["plausible reading A", "plausible reading B"],
    "checked": "spec sections, CLAUDE.md, code reviewed before stopping"
  },

  // present only when status == user_action_required
  "user_action": {
    "task_id": "T2.1.3",
    "action": "exact real-world action the user must perform",
    "evidence_hint": "what the user should report as evidence once done"
  }
}
```

- `complete` — every assigned task was implemented to spec and its tests pass.
- `needs_clarification` — a blocking spec ambiguity was hit. No guessing. The group is
  not verified; the workflow returns the blocker to the coordinating skill, which
  resolves it with the user and re-invokes the workflow for this group.
- `user_action_required` — a task in the group requires a real-world user action no
  agent can perform. The implementable remainder is still implemented; the group cannot
  pass until the user acks. Same bubble-up path as `needs_clarification`.

## wave-verifier → `VERIFY_RESULT`

```jsonc
{
  "verdicts": { "2.1.a": "PASS", "2.1.b": "FAIL" },
  "failures": [
    { "group_id": "2.1.b", "reasons": ["T2.1.4 acceptance criterion 2 MISSING", "weak assertion in tests/bar_test.py::test_x"] }
  ],
  "test_summary": { "passing": 142, "total": 145, "new_failures": ["tests/bar_test.py::test_x"] }
}
```

- One entry in `verdicts` for every task_group the verifier was assigned — no more, no
  fewer. PASS requires every spec element PRESENT, zero rule violations, zero new test
  failures. Everything else is FAIL. No partial or conditional pass.
- `failures` carries the actionable reasons the fix round consumes.

## reviewer → `REVIEW_RESULT`

```jsonc
{
  "phase": 2,
  "verdict": "clean | has-violations",
  "findings": [
    {
      "id": "V1",
      "category": "violation | gap | weak-test | legacy",
      "severity": "critical | major | minor",
      "file": "src/auth/login.py",
      "line": 88,
      "rule": "which rule is violated (for violations/legacy)",
      "evidence": "the offending code/comment/assertion, quoted",
      "fix_hint": "what the correct fix is, for the auto-fix ruleset to classify"
    }
  ]
}
```

## review-spec → `SPEC_REVIEW_RESULT`

```jsonc
{
  "phase": 2,
  "verdict": "ready | needs-revision",
  "findings": [
    {
      "id": "M1",
      "severity": "critical | major | minor | info",
      "classification": "mechanical | decision-required",
      "location": "phase-2 §Task 4 \"Files to modify\"",
      "problem": "what is wrong, quoting the spec text",
      "proposed_fix": "concrete edit a fix-agent can apply (for mechanical)",
      "options": [                                 // for decision-required only
        { "name": "A", "edit": "concrete edit", "pros": "...", "cons": "..." },
        { "name": "B", "edit": "concrete edit", "pros": "...", "cons": "..." }
      ]
    }
  ]
}
```

## fix-agent → `FIX_RESULT`

```jsonc
{
  "files_edited": ["src/auth/login.py"],
  "files_read_unchanged": [],
  "edits": [
    { "source": "auto-fix:weak-test | user-decision:D3 | mechanical:M1", "file": "tests/foo_test.py", "summary": "what changed" }
  ],
  "discoveries": ["for weak-test fixes: what the weak assertion was hiding"],
  "rule_violations_fixed": ["violations introduced by an edit and corrected in-pass"],
  "preexisting_noted": ["issues seen near the edit site, not fixed"],
  "scope_mismatches": [{ "edit": "M2", "file": "x", "reason": "old_string not found" }],
  "test_results": { "passing": 142, "total": 145, "new_failures": [] }
}
```

`scope_mismatches` is non-empty when an edit could not be applied (file not in target
list, ambiguous directive, `old_string` missing). The coordinating skill reissues those.
