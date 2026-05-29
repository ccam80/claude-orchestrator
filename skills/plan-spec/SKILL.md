---
name: plan-spec
description: Take a phase from the implementation plan and produce a detailed implementation spec through collaborative architecting. Every design decision goes through the user.
argument-hint: <phase name or number>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion]
---

# Plan Spec

You are producing a detailed implementation specification for a single phase from the project's implementation plan. You work collaboratively with the user — every design decision goes through them.

## Setup

1. Determine the project root directory (current working directory).
2. Read `spec/plan.md` to find the phase to spec.
3. If `$ARGUMENTS` specifies a phase (by name or number), use that. Otherwise ask the user which phase to spec.
4. Read any existing phase specs in `spec/` to understand what's already been designed.
5. Read the project's `CLAUDE.md` for project-specific conventions.
6. Read relevant source files to understand the existing codebase.
7. Read the spec template from `${SKILL_DIR}/references/spec-template.md`.
8. Read the manifest schema from `${SKILL_DIR}/references/manifest-schema.md`. You are the sole writer of `spec/manifest.json` — the job-control artifact `implement-hybrid` consumes.

## Author Authority

The implementation plan (`spec/plan.md`) is agent-generated. There is no guarantee of correctness until decisions have been explicitly made by the author (the user). The author is the authoritative source of truth on architectural and implementation decisions.

- When a plan decision seems wrong, incomplete, or in tension with the codebase, **say so**. It is expected and encouraged to question the sanity and correctness of the plan during spec work.
- If a spec decision contradicts or improves upon the plan, **update `spec/plan.md` retroactively** to reflect the better decision. The plan is a living document that should match reality, not a frozen contract.
- Never treat the plan as gospel. Treat it as the best guess at time of writing, subject to revision as you dig into details.

## How to Refer to Tasks

Never refer to a task by number or title alone (e.g. "Task 2.1.3" or "the serialization task"). The user does not have the entire plan in memory. Always describe the task's contents and context when discussing it. For example: "the task that adds JSON serialization to the config loader (`config/loader.py`)" rather than "Task 2.1.3."

## How to Present Decisions

**Do not use AskUserQuestion for design decisions.** Interview-style questions force binary or ternary choices, often based on flawed assumptions, and the answer is most often "none of the above" or "some of each."

Instead, present decisions conversationally:

1. **Lay out the design space in prose.** Describe the options, what each implies, and where the tensions are. Use tables for comparing concrete tradeoffs, but wrap them in explanatory text.
2. **Be explicit about what's at stake.** "If we go with X, that means Y for the rest of the system. If we go with Z, we get A but lose B."
3. **End with a recap list of the specific questions** the user needs to answer, so they can respond point-by-point without re-reading the whole discussion.

This gives the user room to say "actually, a mix of options 1 and 3" or "you're missing an option entirely" — which structured interviews prevent.

## Workflow

For each wave and task in the phase:

### 1. Present the Design Space
- Describe the task's purpose and context (never just its number/title).
- Identify the key design decisions for this task.
- Present options and tradeoffs in prose, using tables for concrete comparisons.
- Surface architecture tensions explicitly: "This conflicts with X because..."
- Highlight constraints from the project's CLAUDE.md or existing code.
- If the plan's approach for this task seems wrong or suboptimal, flag it now.

### 2. Get User Decision
- End your design space presentation with a numbered recap of the specific questions.
- Wait for the user to decide on each design choice.
- Do not proceed past a decision point without user input.

### 3. Incorporate the Decision
- Write the decision directly into the spec as a current-state fact.
- The spec reflects outcomes, not history. No "we considered X but chose Y."
- If a decision changes mid-session, update the spec in place — replace, don't append.
- If the decision contradicts the plan, update `spec/plan.md` to match.

### 4. Check Ripple Effects
- After each decision, check whether it affects other tasks in this phase or other phases.
- If it does, note the impact and update the spec accordingly.
- If it affects a different phase's spec, note it for the user but don't modify other spec files.
- If it affects the plan itself, update `spec/plan.md` to reflect the new reality.

### 5. Define Specifics
For each task, define:
- **Files to create**: exact paths, purpose, key classes/functions to define
- **Files to modify**: exact paths, what to change, specific functions affected
- **Tests**: exact test paths, class names, method names, and what each test asserts
- **Acceptance criteria**: concrete, testable statements

Every field above must be an enumerated list. No open-ended phrasing, no class-of-files descriptions, no "and related files." See the **Specs Are Concrete — No Implementer Discovery** section below: if you find yourself wanting to write "wherever applicable" or "find all uses of...", stop and run the discovery yourself (Grep/Glob/Read) before writing the spec entry.

### 6. Declare the Phase's File Footprint
Populate the **Files Owned** section at the top of the spec by enumerating every file that any task in this phase creates or modifies. This is the deduplicated union of every task's `Files to create` + `Files to modify`. No file in another feature phase's "Files Owned" list may appear here — if a conflict surfaces, escalate to the user; do not silently overlap. (Phase 0 and the Legacy Reference Review phase are excepted from this constraint by design.)

### 7. Form Task Groups Per Wave
For each wave, form **task_groups** and record them in `spec/manifest.json` (see step 9 — Write the Manifest). A task_group is the set of tasks one implementer will own end-to-end. The coordinator reads these from the manifest verbatim and spawns one implementer per group. Task_groups live ONLY in the manifest — do not write a Task Groups table into the phase spec file.

Form groups by these rules, in order:
1. **File locality binds.** Two tasks that touch the same file MUST be in the same group. Groups in a batch run as concurrent implementers, so two groups sharing a file means two agents writing it at once — their edits clobber each other. There is no lock to save you; file-disjoint groups are the mechanism.
2. **Hard cap: 10 files per group** (the union of every task's Files to create + Files to modify across the group). Target 4–6. If a group exceeds 10 files, split it. If splitting forces two groups to touch the same file, the phase is wrongly scoped — escalate to the user.
3. **Complexity influences sizing within the cap.** A group of L-complexity tasks should be smaller than a group of S-complexity tasks; an agent's reading + reasoning budget is the limit, not the file count alone.
4. **One implementer per group.** Do not propose groups that "could be split if needed" — commit to a structure.

### 8. Author Mechanical-Edit Tasks With Strict Discipline
A "mechanical edit" task is a rename, regex replacement, config-key migration, import-path fix, API-symbol swap — anything where the same shape of change is applied at multiple known locations. These tasks are highly delegate-able BUT only if you author them per the **Mechanical-Edit Task Pattern** in `spec-template.md`. That pattern is non-optional for any task you classify as mechanical:

- **You enumerate every affected reference** (file:line, before-text) in the spec by running Grep/Glob now. The implementer does NOT re-search.
- **Dry-run is compulsory.** The task's first implementation step is a dry-run that lists every intended edit; the dry-run output must match your enumerated references exactly before any real edit is applied. Mismatch → Clarification Exit.
- **Encoding controls are mandatory.** All reads/writes UTF-8 no BOM; no silent encoding conversion; post-edit mojibake smoke check (U+FFFD, common Latin-1-as-UTF-8 sequences) is a FAIL condition; line endings preserved per file.
- **Scripted, not hand-edited.** The task is executed via a script the implementer writes and runs (sed pipeline, small Python script, etc.) — not by repeated `Edit` calls. You specify the script approach.

If you cannot enumerate the affected references — if you're tempted to write "everywhere it appears" — the task is not yet specced. Run the search yourself first, then enumerate, then write the task.

### 9. Write the Manifest
After the phase spec is settled, record this phase's slice in `spec/manifest.json` following `${SKILL_DIR}/references/manifest-schema.md`. The manifest is the job-control artifact `implement-hybrid` consumes — task_groups have no other home.

- **Create-if-absent.** If `spec/manifest.json` does not exist, create it with `test_command` (from the project `CLAUDE.md`), `verification` (the final acceptance checks from `spec/plan.md`'s Verification section), and an empty `phases` array.
- **Rewrite this phase's slice.** Read the existing manifest, replace this phase's entry (or append it if new), and write the whole file back. Keep `phases` ordered by phase number; keep `waves` in execution order. Never hand-edit another phase's slice.
- **Per phase**, record `phase`, `name`, `spec_file`, `depends_on`, and `waves`. Per wave, record every task_group from step 7 as `{group_id, tasks, user_required_tasks}`. Each task carries its `id` and `complexity` (`S`/`M`/`L`, from `spec/plan.md`).
- **`depends_on`.** Transcribe this phase's `**Depends on**:` line from `spec/plan.md` into a phase-number array — the direct prerequisites only (e.g. `**Depends on**: Phase 1` → `"depends_on": [1]`; Phase 0 → `[]`; the Legacy Reference Review phase → every other phase number). This is a local fact about your phase, so it stays inside your per-phase write boundary. `implement-hybrid` reads it to compute parallel tiers and merge sibling phases' waves into concurrent batches; an omitted or wrong `depends_on` produces a wrong schedule, and there is no fallback — `review-spec` fails a manifest where any phase lacks it. If `plan.md` has no parseable `**Depends on**:` line for this phase, stop and fix the plan first; do not invent the dependency.
- **`user_required_tasks`.** For each task_group, list the task IDs whose spec explicitly requires a real-world user action (the user must configure, provide, verify, deploy, or otherwise act where no agent can). Empty list if none. `implement-hybrid`'s user-required gate is seeded directly from this field — a task you omit here cannot be acked, so the group would stall. Enumerate carefully.
- If a spec decision changed the phase/wave/task structure, the manifest slice you write must match the final spec — they are checked for consistency by `review-spec`.

## Spec File Principle

Spec files are current-state contracts. They contain ONLY what to build:
- No decision history
- No changelogs
- No "previously we considered X"
- No "this was changed from Y to Z"

If a decision changes mid-session, the spec is updated in place. The final spec reads as if the current design was always the plan.

## Specs Are Concrete — No Implementer Discovery

Implementers execute exactly what is specified. They do not investigate, audit, search, sample, or adjust their work in response to what they find. All discovery work belongs to the spec author — you — and must be completed BEFORE the spec is written.

**Banned phrasings.** Never write tasks, files, tests, or acceptance criteria that contain:
- "verify X exists" / "verify Y is present" / "check that Z is correct"
- "find all cases of...", "search for all uses of...", "identify any remaining..."
- "...and others", "...and similar", "...and any related files", "etc."
- "audit", "review", "scan", "sweep" (when used to mean "discover what's there")
- "if X exists, then..." / "wherever applicable" / "update as needed"
- "ensure consistency with the rest of the codebase"
- Open-ended file lists ("relevant files in `src/foo/`") instead of explicit paths
- Any phrasing that requires the implementer to decide scope based on what they observe

**The rule.** If a task needs discovery to define its scope, you do the discovery now (with Grep, Glob, Read) and then write the spec with the enumerated, concrete result. The spec lists exact files, exact symbols, exact lines, exact test names. An implementer reading the spec must never have to ask "which ones?" or "where?"

**Legacy-reference / audit phases are not an exception.** If the plan includes a "find and remove remaining references" phase, you run those searches during spec authoring and enumerate every hit in the spec. The implementer deletes a known list — they do not re-run the search.

If discovery during spec authoring reveals the scope is too large to enumerate, that is a planning problem: surface it to the user and adjust the plan. Do not paper over it with vague task descriptions.

## Output

After all tasks are specced, present the complete spec for user review. Then write two files:

1. The approved phase spec to:
   ```
   spec/phase-{n}-{name}.md
   ```
   Where `{n}` is the phase number and `{name}` is the phase name in kebab-case (lowercase, hyphens for spaces). Use the format from `${SKILL_DIR}/references/spec-template.md`.

2. This phase's slice of `spec/manifest.json` (step 9 — Write the Manifest), following `${SKILL_DIR}/references/manifest-schema.md`.

## Shell Safety (Windows)

This project runs on Windows with Git Bash. All bash commands MUST:
- **Double-quote all paths** — backslashes are escape characters in unquoted strings.
- **Use forward slashes** in paths.
- **Use `/dev/null`**, never `NUL`.

## Important

- Tests must specify exact assertions, not vague "test that it works" statements.
- File paths must be specific — no "somewhere in the utils directory."
- Acceptance criteria must be concrete enough that a different person could verify them.
- Every task must have at least one test specified.
- Keep the spec focused on WHAT to build, not HOW to build it (implementation details are left to the implementer unless architecturally significant).
