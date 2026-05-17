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
| `implement-hybrid` | Reads it once at setup to build `spec/.hybrid-state.json`. Never writes it. |

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
`waves` is in execution order. `implement-hybrid` flattens `phases` → `waves`
into a linear batch sequence in exactly this array order; one wave becomes one
batch. Do not reorder either array for any other purpose.

## Invariants

- Every task ID in the manifest must exist as a task in the named `spec_file`.
- Every task in a wave appears in exactly one task_group — no unassigned tasks,
  no task in two groups.
- Every ID in `user_required_tasks[group]` must be one of that group's task IDs.
- Task_group file-locality and the 10-file cap are not stored in the manifest;
  `review-spec` validates them by cross-referencing the manifest's task_groups
  against the per-task `Files to create` / `Files to modify` lists in the phase
  spec.
