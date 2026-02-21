# {Project Name} — Implementation Plan

## Goals
- {Concrete deliverable 1}
- {Concrete deliverable 2}

## Non-Goals
- {Explicitly excluded item 1}

## Verification
- {How we know phase 0 removed all dead code}
- {How we know phase 1 is correct}
- {How we know the whole thing works}
- {How we know no legacy references remain (final phase)}

## Dependency Graph

```
Phase 0 (Dead Code Removal)         ─── runs first, alone
│
Phase 1 ({Name})                     ─── after 0
├──→ Phase 2 ({Name})     ─── parallel after 1 ──┐
├──→ Phase 3 ({Name})     ─── parallel after 1    │
│                                                  │
│    Phase 4 ({Name})     ─── after 3              │
│                                                  │
└──→ Phase 5 ({Name})    ─── after 4 + 2 ──────────┘
│
Phase N (Legacy Reference Review)    ─── runs last, after all
```

Phases are numbered in execution order. Phases that can start in parallel
after the same dependency have consecutive numbers.

Phase 0 and the final phase are mandatory in every plan.

---

## Phase 0: Dead Code Removal
**Depends on**: (none — runs first)

Remove all code, tests, imports, references, config entries, and documentation
that will become dead or obsolete as a result of this plan. This will break
the build and tests — that is expected. Subsequent phases build the replacements.

### Wave 0.1: Identify and Remove Dead Code
| Task | Description | Complexity | Key Files |
|------|-------------|------------|-----------|
| 0.1.1 | {Identify all code/tests/imports to be replaced by this plan and delete them} | M | {files} |

---

## Phase 1: {Name}
**Depends on**: Phase 0

### Wave 1.1: {Description}
| Task | Description | Complexity | Key Files |
|------|-------------|------------|-----------|
| 1.1.1 | ... | S/M/L | ... |
| 1.1.2 | ... | S/M/L | ... |

### Wave 1.2: {Description}
| Task | Description | Complexity | Key Files |
|------|-------------|------------|-----------|
| 1.2.1 | ... | S/M/L | ... |

## Phase 2: {Name}
**Depends on**: Phase 1
**Parallel with**: Phase 3

### Wave 2.1: {Description}
| Task | Description | Complexity | Key Files |
|------|-------------|------------|-----------|
| 2.1.1 | ... | S/M/L | ... |

---

## Phase {N}: Legacy Reference Review
**Depends on**: all previous phases

Audit the entire repository for any remaining references to removed code:
imports, type annotations, string literals, config values, documentation,
test fixtures, comments. No legacy references are acceptable in any form.

### Wave {N}.1: Full Legacy Audit
| Task | Description | Complexity | Key Files |
|------|-------------|------------|-----------|
| {N}.1.1 | Search for and remove all stale references to code removed in Phase 0 and replaced in subsequent phases | M | (repo-wide) |
