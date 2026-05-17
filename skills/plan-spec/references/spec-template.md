# Phase {N}: {Name}

## Overview
{What this phase accomplishes}

## Files Owned

Enumerate every file this phase creates or modifies. This is the phase's
authoritative file footprint, used by review-spec for cross-phase conflict
detection and by plan-spec to form task_groups. The same file must not appear
in another feature phase's "Files Owned" list.

- `path/to/file_a.py` — created
- `path/to/file_b.py` — modified
- `tests/test_file_a.py` — created
- `tests/test_file_b.py` — modified

> **Task groups are not declared here.** They live in `spec/manifest.json`,
> written by plan-spec (step 7 — Form Task Groups Per Wave; step 9 — Write the
> Manifest). The phase spec carries task *content* only; the manifest carries
> the implementer assignment structure.

## Wave {N}.1: {Description}

### Task {N}.1.1: {Title}
- **Description**: {What to build}
- **Files to create**:
  - `path/to/file.py` — {purpose, key classes/functions to define}
- **Files to modify**:
  - `path/to/existing.py` — {what to change, specific functions}
- **Tests**:
  - `tests/test_file.py::TestClassName::test_method` — assert {specific behaviour}
  - `tests/test_file.py::TestClassName::test_edge_case` — assert {specific behaviour}
- **Acceptance criteria**:
  - {Concrete, testable statement}
  - All tests pass

### Task {N}.1.2: {Title}
- **Description**: {What to build}
- **Files to create**:
  - `path/to/file.py` — {purpose}
- **Files to modify**:
  - `path/to/existing.py` — {what to change}
- **Tests**:
  - `tests/test_file.py::TestClassName::test_method` — assert {specific behaviour}
- **Acceptance criteria**:
  - {Concrete, testable statement}
  - All tests pass

## Wave {N}.2: {Description}

### Task {N}.2.1: {Title}
- **Description**: {What to build}
- **Files to create**:
  - `path/to/file.py` — {purpose}
- **Tests**:
  - `tests/test_file.py::TestClassName::test_method` — assert {specific behaviour}
- **Acceptance criteria**:
  - {Concrete, testable statement}
  - All tests pass

## Mechanical-Edit Task Pattern (use whenever the task is repetitive across many files)

A "mechanical edit" task is a rename, a regex replacement, a config-key
migration, an import-path fix, an API-symbol swap — anything where the
change is the *same shape* applied to a known set of locations. These tasks
are the most reliable to delegate to an agent IF — and only if — the spec is
authored as a scripted task with dry-run discovery up front.

When you write a mechanical-edit task, structure it like this:

### Task {N}.x.y: {Mechanical change title}
- **Description**: {what conceptually changes — e.g. "rename `OldName` →
  `NewName` everywhere it appears in code, tests, fixtures, and string
  literals"}
- **Affected references (authoritative — enumerated by author)**:
  Author runs the search now (Grep/Glob) and lists every match here, with
  file path and line number. Implementer does NOT re-search. Example:
  - `src/foo.py:42` — `class OldName:`
  - `src/foo.py:101` — `OldName(...)`
  - `tests/test_foo.py:7` — `from src.foo import OldName`
  - `docs/api.md:88` — "Use `OldName` to..."
- **Dry-run requirement (compulsory)**:
  The implementer's first step is to produce a dry-run output that lists
  every change it intends to make — file, line, before, after — and halt
  before applying any edit. The dry-run output is compared against
  "Affected references" above. If the dry-run finds more, fewer, or
  different locations than the author enumerated, the task FAILS and the
  implementer takes the Clarification Exit. No edits are applied until the
  dry-run matches the author's list exactly.
- **Encoding controls (mandatory for any text replacement)**:
  - All files read and written as UTF-8 with no BOM.
  - No encoding conversion mid-edit; if the file is currently in a
    different encoding, that itself is a separate task — flag it in the
    Clarification Exit rather than re-encoding silently.
  - `mojibake` smoke check: after edits, grep for the U+FFFD replacement
    character and for common mojibake sequences (`â€™`, `â€œ`, `â€`,
    `Ã©`, `Ã¨`, `Ã ` in files that should be ASCII-only). Any hit = task
    FAILS.
  - Line endings preserved per-file (do not convert CRLF↔LF as a side
    effect of the edit).
- **Implementation method (mandatory — script, not manual editing)**:
  The task MUST be executed via a script the implementer writes and runs,
  not by hand-editing each location with `Edit`. The author specifies the
  script approach: e.g. `sed`-driven, a small Python script using
  `pathlib` + `str.replace`, a `git grep`-driven `xargs sed`. Author
  picks the tool; implementer writes and runs the script; the dry-run
  output is the script's `--dry-run` (or equivalent) run.
- **Tests**:
  - `tests/test_foo.py::TestClassName::test_renamed_symbol` — asserts
    `NewName` is importable and behaves identically to the old `OldName`
  - {Plus any other concrete assertion the change requires}
- **Acceptance criteria**:
  - Dry-run output matched "Affected references" exactly (no extras, no
    misses).
  - Mojibake smoke check passed.
  - All tests pass.

Mechanical tasks that cannot enumerate their affected references — or whose
"Affected references" is just "everywhere it appears" — are spec failures.
Fix the spec, do not delegate the discovery to the implementer.
