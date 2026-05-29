export const meta = {
  name: 'co-implement-batch',
  description: 'Implement one batch of task_groups in parallel, verify each, and run up to 2 headless fix rounds on failures',
  phases: [
    { title: 'Implement', detail: 'one implementer per task_group, concurrently' },
    { title: 'Verify', detail: 'one wave-verifier per <=4 task_groups, phase-partitioned' },
    { title: 'Fix', detail: 'fix-implement failed groups and re-verify, max 2 rounds' },
  ],
}

// ── args contract (passed by the implement-hybrid skill) ──────────────────────
//   project_dir   absolute project root
//   plugin_root   absolute claude-orchestrator plugin root (for references/)
//   test_command  the project's full test-suite command
//   baseline_file path to spec/test-baseline.md (relative to project_dir)
//   batch: {
//     id,
//     groups: [{
//       group_id, phase, spec_file,
//       tasks: [{ id, title, complexity }],          // complexity S|M|L
//       user_required_tasks: [taskId],               // from the manifest
//       acked_user_tasks:   [taskId],                // already acked by the user
//     }]
//   }
const { project_dir, plugin_root, test_command, baseline_file, batch } = args
const groups = batch.groups

const IMPL_SCHEMA = {
  type: 'object',
  required: ['group_id', 'status', 'files_created', 'files_modified', 'tasks'],
  properties: {
    group_id: { type: 'string' },
    status: { enum: ['complete', 'needs_clarification', 'user_action_required'] },
    files_created: { type: 'array', items: { type: 'string' } },
    files_modified: { type: 'array', items: { type: 'string' } },
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'status'],
        properties: { id: { type: 'string' }, status: { enum: ['complete', 'not_started'] } },
      },
    },
    clarification: {
      type: 'object',
      properties: {
        task_id: { type: 'string' }, summary: { type: 'string' },
        spec_quote: { type: 'string' }, readings: { type: 'array', items: { type: 'string' } },
        checked: { type: 'string' },
      },
    },
    user_action: {
      type: 'object',
      properties: { task_id: { type: 'string' }, action: { type: 'string' }, evidence_hint: { type: 'string' } },
    },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['verdicts', 'failures', 'test_summary'],
  properties: {
    verdicts: { type: 'object', additionalProperties: { enum: ['PASS', 'FAIL'] } },
    failures: {
      type: 'array',
      items: {
        type: 'object',
        required: ['group_id', 'reasons'],
        properties: { group_id: { type: 'string' }, reasons: { type: 'array', items: { type: 'string' } } },
      },
    },
    test_summary: {
      type: 'object',
      required: ['passing', 'total', 'new_failures'],
      properties: {
        passing: { type: 'number' }, total: { type: 'number' },
        new_failures: { type: 'array', items: { type: 'string' } },
      },
    },
  },
}

const rank = (c) => ({ S: 0, M: 1, L: 2 }[c] ?? 1)
const modelForGroup = (g) => (g.tasks.every((t) => rank(t.complexity) === 0) ? 'haiku' : 'sonnet')

// Phase-partitioned chunking: a verifier reads exactly one phase spec, <=4 groups.
function chunkBySpec(groupList) {
  const bySpec = {}
  for (const g of groupList) (bySpec[g.spec_file] ||= []).push(g)
  const chunks = []
  for (const gs of Object.values(bySpec))
    for (let i = 0; i < gs.length; i += 4) chunks.push({ spec_file: gs[i].spec_file, groups: gs.slice(i, i + 4) })
  return chunks
}

const tasksTable = (g) =>
  g.tasks.map((t) => `| ${t.id} | ${t.title} | ${t.complexity} |`).join('\n')

function implementerPrompt(g, fixReasons) {
  const fixBlock = fixReasons
    ? `\n## This is a FIX round\nA prior implementation of this group FAILED verification. Address every reason below, then re-run tests:\n${fixReasons.map((r) => `- ${r}`).join('\n')}\n`
    : ''
  const ackedNote = g.user_required_tasks.length
    ? `\n## User-required tasks in this group\n${g.user_required_tasks
        .map((id) => `- ${id} — ${g.acked_user_tasks.includes(id) ? 'ACKED by user, proceed' : 'NOT acked — return user_action_required for this task, implement everything else'}`)
        .join('\n')}\n`
    : ''
  return `# Implementation Assignment

## Project
- **Root**: ${project_dir}
- **Phase spec file**: ${g.spec_file}
- **Rules file**: ${plugin_root}/references/rules.md
- **Test baseline**: ${baseline_file}

## Your task_group: ${g.group_id} (phase ${g.phase})
Implement every task below, end-to-end, exactly as the spec specifies. Self-continue
through them in order. Do not pick up tasks outside this group.

| ID | Title | Complexity |
|----|-------|------------|
${tasksTable(g)}
${ackedNote}${fixBlock}
## Before anything else, read
- ${plugin_root}/references/rules.md — non-negotiable rules (includes shell safety)
- ${g.spec_file} — find each task by ID for its full specification
- ${project_dir}/CLAUDE.md — project conventions
- ${baseline_file} — pre-existing test failures (distinguish from regressions you cause)

Return the IMPL_RESULT structured object. Do NOT write to any state file or run any
recording script — your structured return IS the record.`
}

function verifierPrompt(chunk) {
  const ids = chunk.groups.map((g) => g.group_id)
  const perGroup = chunk.groups
    .map((g) => `- **${g.group_id}**: tasks ${g.tasks.map((t) => t.id).join(', ')}${g.user_required_tasks.length ? ` — user-required: ${g.user_required_tasks.join(', ')} (acked: ${g.acked_user_tasks.join(', ') || 'none'})` : ''}`)
    .join('\n')
  return `# Wave Verification Assignment

## Project
- **Root**: ${project_dir}
- **Phase spec file**: ${chunk.spec_file}
- **Rules file**: ${plugin_root}/references/rules.md
- **Test command**: ${test_command}
- **Test baseline**: ${baseline_file}

## Verify ONLY these task_groups (all from the one phase spec above)
${perGroup}

A user-required task with no recorded user ack is an automatic FAIL for its group —
the assignment marks which task_ids are acked.

## Before anything else, read
- ${chunk.spec_file} — task specifications (find each task by ID)
- ${plugin_root}/references/rules.md — rules to check against
- ${project_dir}/CLAUDE.md — project conventions
- ${baseline_file} — pre-existing failures (do not count them as regressions)

Return the VERIFY_RESULT structured object with a verdict for each of: ${ids.join(', ')}.`
}

async function verifyGroups(groupList, phaseTitle) {
  const chunks = chunkBySpec(groupList)
  const results = await parallel(
    chunks.map((c) => () =>
      agent(verifierPrompt(c), {
        label: `verify:${c.groups.map((g) => g.group_id).join(',')}`,
        phase: phaseTitle,
        agentType: 'claude-orchestrator:wave-verifier',
        model: 'sonnet',
        schema: VERIFY_SCHEMA,
      }),
    ),
  )
  const verdicts = {}
  const failures = []
  for (const r of results.filter(Boolean)) {
    Object.assign(verdicts, r.verdicts)
    failures.push(...r.failures)
  }
  return { verdicts, failures }
}

// ── 1. Implement ──────────────────────────────────────────────────────────────
phase('Implement')
const implResults = await parallel(
  groups.map((g) => () =>
    agent(implementerPrompt(g), {
      label: `impl:${g.group_id}`,
      phase: 'Implement',
      agentType: 'claude-orchestrator:implementer',
      model: modelForGroup(g),
      schema: IMPL_SCHEMA,
    }),
  ),
)

const byId = Object.fromEntries(groups.map((g) => [g.group_id, g]))
const files = {}
const blockers = []
const completedIds = []
const deadIds = []
implResults.forEach((r, i) => {
  if (!r) { deadIds.push(groups[i].group_id); return }
  files[r.group_id] = { created: r.files_created, modified: r.files_modified }
  if (r.status === 'needs_clarification') blockers.push({ group_id: r.group_id, type: 'clarification', detail: r.clarification })
  else if (r.status === 'user_action_required') blockers.push({ group_id: r.group_id, type: 'user_action', detail: r.user_action })
  else completedIds.push(r.group_id)
})
if (deadIds.length) log(`implementer(s) returned no result for: ${deadIds.join(', ')} — coordinator should re-invoke`)
log(`implemented ${completedIds.length}/${groups.length}; blockers: ${blockers.length}; dead: ${deadIds.length}`)

// ── 2. Verify ───────────────────────────────────────────────────────────────
phase('Verify')
const verdicts = {}
let outstandingFailures = []
if (completedIds.length) {
  const v = await verifyGroups(completedIds.map((id) => byId[id]), 'Verify')
  Object.assign(verdicts, v.verdicts)
  outstandingFailures = v.failures
}

// ── 3. Fix rounds (headless — no human needed for a FAIL) ─────────────────────
phase('Fix')
let round = 0
while (outstandingFailures.length && round < 2) {
  round++
  log(`fix round ${round}: ${outstandingFailures.length} failed group(s)`)
  const reasonsById = Object.fromEntries(outstandingFailures.map((f) => [f.group_id, f.reasons]))
  const failedGroups = outstandingFailures.map((f) => byId[f.group_id])

  await parallel(
    failedGroups.map((g) => () =>
      agent(implementerPrompt(g, reasonsById[g.group_id]), {
        label: `fix:${g.group_id}`,
        phase: 'Fix',
        agentType: 'claude-orchestrator:implementer',
        model: modelForGroup(g),
        schema: IMPL_SCHEMA,
      }),
    ),
  )
  const rv = await verifyGroups(failedGroups, 'Fix')
  Object.assign(verdicts, rv.verdicts)
  outstandingFailures = rv.failures.filter((f) => rv.verdicts[f.group_id] === 'FAIL')
}

// Mark blocked groups so the coordinator never reads them as passed.
for (const b of blockers) verdicts[b.group_id] = 'BLOCKED'
for (const id of deadIds) verdicts[id] = 'DEAD'

return {
  batch_id: batch.id,
  verdicts,            // group_id -> PASS | FAIL | BLOCKED | DEAD
  blockers,            // [{group_id, type, detail}] — coordinator resolves with the user
  failures: outstandingFailures, // groups still FAIL after 2 rounds
  files,               // group_id -> {created, modified}
}
