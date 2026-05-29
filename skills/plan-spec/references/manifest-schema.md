# Manifest Schema — `spec/manifest.json`

`spec/manifest.json` is the **job-control artifact** for implementation. It is
the single file `implement-hybrid` reads to build its batch plan: the ordered
phases, the waves within each phase, the task_groups within each wave, the
per-task complexity, and the user-required task flags.

`spec/plan.md` is an architecture and planning document — goals, dependency
graph, design rationale, human discussion. It is **not read by the
implementation runtime**. The manifest is. Keep the two roles separate: never
treat `plan.md` as a job manifest, and never put planning prose in the manifest.

## Who reads and writes it

| Skill / agent | Role |
|---|---|
| `plan-spec` | **Sole writer.** Each run rewrites its phase's slice of the manifest, creating the file if absent. |
| `review-spec` | Validates the manifest against the phase specs. Never writes it. |
| `implement-hybrid` | Reads it to compute the tier/batch schedule it drives the implement workflow with. Never writes it. |

## Structure

```json
{
  "test_command": "pytest -q",
  "verification": [
    "Acceptance check 1 — concrete, runnable",
    "Acceptance check 2 — concrete, runnable"
  ],
  "phases": [
    {
      "phase": 1,
      "name": "shared-core",
      "spec_file": "spec/phase-1-shared-core.md",
      "depends_on": [0],
      "waves": [
        {
          "wave": "1.1",
          "task_groups": [
            {
              "group_id": "1.1.a",
              "tasks": [
                { "id": "T1.1.1", "complexity": "M" },
                { "id": "T1.1.2", "complexity": "S" }
              ],
              "user_required_tasks": []
            },
            {
              "group_id": "1.1.b",
              "tasks": [
                { "id": "T1.1.3", "complexity": "L" }
              ],
              "user_required_tasks": ["T1.1.3"]
            }
          ]
        },
        {
          "wave": "1.2",
          "task_groups": [
            {
              "group_id": "1.2.a",
              "tasks": [
                { "id": "T1.2.1", "complexity": "S" }
              ],
              "user_required_tasks": []
            }
          ]
        }
      ]
    }
  ]
}
```

## Field reference

| Field | Type | Meaning |
|---|---|---|
| `test_command` | string | The project's full test-suite command. Sourced from the project `CLAUDE.md` / `plan.md` by `plan-spec`. |
| `verification` | string[] | The final acceptance checks, run by `implement-hybrid` after all phases complete. Concrete and runnable — not "it works". Sourced from `plan.md`'s Verification section. |
| `phases` | object[] | Phases in **execution order** (see Ordering). |
| `phases[].phase` | int | Phase number. |
| `phases[].name` | string | Phase name, kebab-case. |
| `phases[].spec_file` | string | Path to the phase spec file, relative to project root. `implement-hybrid` hands this to implementers and verifiers. |
| `phases[].depends_on` | int[] | Phase numbers this phase depends on (its direct prerequisites). `[]` for Phase 0. The Legacy Reference Review phase lists every other phase. `implement-hybrid` uses this to compute parallel **tiers** and merge sibling phases' waves into concurrent batches — see **Parallel scheduling**. Required on every phase. |
| `phases[].waves` | object[] | Waves in **execution order** within the phase (later waves depend on earlier ones). |
| `phases[].waves[].wave` | string | Wave label, e.g. `"1.1"`. |
| `phases[].waves[].task_groups` | object[] | One entry per implementer assignment. Formed by `plan-spec` using file-locality + the 10-file cap. |
| `task_groups[].group_id` | string | Unique group identifier. |
| `task_groups[].tasks` | object[] | The tasks this one implementer owns end-to-end. |
| `task_groups[].tasks[].id` | string | Task ID — must match a task ID in the phase spec. |
| `task_groups[].tasks[].complexity` | string | `S`, `M`, or `L`. Drives implementer model selection (`S`→haiku, `M`/`L`→sonnet). |
| `task_groups[].user_required_tasks` | string[] | Task IDs in this group whose spec explicitly requires a real-world user action. Empty list if none. `implement-hybrid` copies this verbatim into the state file's gate. |

## Ordering

The `phases` array is in **execution order** — `plan-orchestrated` numbers
phases in execution order, and the manifest preserves it. Within a phase,
`waves` is in execution order. The array order is the tie-breaker for batch
numbering, but it does not by itself define the schedule — `depends_on` does
(see **Parallel scheduling**). Do not reorder either array for any other
purpose.

## Parallel scheduling

`depends_on` is the machine-readable form of `plan.md`'s dependency graph, and
it is what makes the manifest phase-parallel. `implement-hybrid` does not run
phases strictly one-after-another; it schedules from `depends_on`:

1. **Tiers.** Phases are layered by their longest dependency path from the
   roots. Phase 0 is tier 0. Every phase whose `depends_on` is satisfied by
   tier 0 is tier 1, and so on. Phases in the same tier are **siblings** — they
   have no dependency path between them and run concurrently.
2. **Wave-position merge within a tier.** For each tier, the *k*-th wave of
   every phase in that tier is merged into one batch: `batch_k` is the union of
   wave *k* across all the tier's phases (phases with fewer than *k* waves drop
   out of later batches). This preserves intra-phase wave order (wave *k* always
   precedes wave *k+1* of the same phase) while running the sibling phases at
   the same time.
3. **Tiers execute in order.** Every batch of tier *t* completes and verifies
   before any batch of tier *t+1* — the prerequisite relationship `depends_on`
   encodes.

A merged batch therefore contains task_groups from multiple phases. This is
safe **only because sibling phases are file-disjoint** (see Invariants) — there
is no lock contention between concurrent implementers from different phases in
the same tier. `review-spec` enforces that disjointness as a hard gate.

## Invariants

- Every task ID in the manifest must exist as a task in the named `spec_file`.
- Every task in a wave appears in exactly one task_group — no unassigned tasks,
  no task in two groups.
- Every ID in `user_required_tasks[group]` must be one of that group's task IDs.
- Task_group file-locality and the 10-file cap are not stored in the manifest;
  `review-spec` validates them by cross-referencing the manifest's task_groups
  against the per-task `Files to create` / `Files to modify` lists in the phase
  spec.
- Every phase has a `depends_on` array. Each entry is a real phase number that
  is strictly earlier in execution order; the graph is acyclic; and it matches
  the `Depends on` lines / dependency graph in `plan.md`.
- **Sibling phases are file-disjoint.** Any two phases in the same tier (no
  dependency path between them) must have non-overlapping file footprints — no
  file in one sibling's `Files Owned` may appear in another's. This is what
  makes the wave-position merge safe; `review-spec` fails the manifest if it is
  violated.
- **File-overlap-exempt phases run alone.** Phase 0 (Dead Code Removal) and the
  Legacy Reference Review phase span arbitrary files by design, so they must be
  the sole member of their tier. The tiering gives this for free — everything
  depends transitively on Phase 0, and the final phase depends on every other
  phase — but `review-spec` asserts it.
