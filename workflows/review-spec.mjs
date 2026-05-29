export const meta = {
  name: 'co-review-spec',
  description: 'Fan out one spec-reviewer per phase, run deterministic cross-phase checks in JS, and one semantic cross-phase agent',
  phases: [
    { title: 'Review', detail: 'one review-spec agent per phase' },
    { title: 'Cross-phase', detail: 'JS structural checks + one semantic agent' },
  ],
}

// ── args contract (passed by the review-spec skill) ───────────────────────────
//   project_dir, plugin_root
//   manifest      the parsed spec/manifest.json
//   phases: [{ phase, name, spec_file }]   // phases in scope
const { project_dir, plugin_root, manifest, phases } = args

const FINDING = {
  type: 'object',
  required: ['id', 'severity', 'classification', 'location', 'problem'],
  properties: {
    id: { type: 'string' },
    severity: { enum: ['critical', 'major', 'minor', 'info'] },
    classification: { enum: ['mechanical', 'decision-required'] },
    location: { type: 'string' },
    problem: { type: 'string' },
    proposed_fix: { type: 'string' },
    options: {
      type: 'array',
      items: {
        type: 'object',
        properties: { name: { type: 'string' }, edit: { type: 'string' }, pros: { type: 'string' }, cons: { type: 'string' } },
      },
    },
  },
}

const SPEC_REVIEW_SCHEMA = {
  type: 'object',
  required: ['phase', 'verdict', 'findings', 'files_owned'],
  properties: {
    phase: { type: 'number' },
    verdict: { enum: ['ready', 'needs-revision'] },
    findings: { type: 'array', items: FINDING },
    files_owned: {
      type: 'array',
      items: {
        type: 'object',
        required: ['path', 'mode'],
        properties: { path: { type: 'string' }, mode: { enum: ['created', 'modified'] } },
      },
    },
  },
}

const CROSS_SEMANTIC_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: { findings: { type: 'array', items: FINDING } },
}

// ── 1. Per-phase review ───────────────────────────────────────────────────────
const specReviewPrompt = (p) => `# Spec Review Assignment

## Project
- **Root**: ${project_dir}
- **Phase spec file**: ${p.spec_file}
- **Plan file**: ${project_dir}/spec/plan.md
- **Manifest file**: ${project_dir}/spec/manifest.json
- **Rules file**: ${plugin_root}/references/rules.md
- **Report path**: ${project_dir}/spec/reviews/spec-phase-${p.phase}.md

## Review scope: Phase ${p.phase} — ${p.name}
Audit this phase spec across all seven review dimensions. Do NOT run cross-phase checks
(shared files, duplicate tasks, dependency respect) — the workflow does those.

## Before anything else, read
- ${plugin_root}/references/rules.md — rules the spec must support
- ${project_dir}/spec/plan.md — full plan (for plan-coverage checks)
- ${p.spec_file} — the phase spec to review
- ${project_dir}/spec/manifest.json — for Task Groups Validity (your phase's slice)
- ${project_dir}/CLAUDE.md — project conventions

Write your full report to the report path, then return the SPEC_REVIEW_RESULT object,
including \`files_owned\` (the exact contents of the spec's Files Owned section).`

phase('Review')
const reviews = (
  await parallel(
    phases.map((p) => () =>
      agent(specReviewPrompt(p), {
        label: `spec-review:phase-${p.phase}`,
        phase: 'Review',
        agentType: 'claude-orchestrator:review-spec',
        model: 'sonnet',
        schema: SPEC_REVIEW_SCHEMA,
      }),
    ),
  )
).filter(Boolean)

// ── 2. Deterministic cross-phase checks (pure JS — no agent, no tokens) ────────
phase('Cross-phase')
const cross = []
const mph = manifest.phases || []
const byNum = Object.fromEntries(mph.map((p) => [p.phase, p]))

// depends_on integrity: present, real, strictly-earlier, acyclic
for (const p of mph) {
  if (!Array.isArray(p.depends_on)) {
    cross.push({ id: `X-${p.phase}-dep`, severity: 'critical', classification: 'decision-required', location: `manifest phase ${p.phase}`, problem: `phase ${p.phase} has no depends_on array — the runtime cannot schedule it` })
    continue
  }
  for (const d of p.depends_on) {
    if (d === p.phase) cross.push({ id: `X-${p.phase}-self`, severity: 'critical', classification: 'mechanical', location: `manifest phase ${p.phase}`, problem: `phase ${p.phase} depends on itself`, proposed_fix: `remove ${d} from depends_on` })
    else if (!(d in byNum) && d !== 0) cross.push({ id: `X-${p.phase}-missing`, severity: 'critical', classification: 'decision-required', location: `manifest phase ${p.phase}`, problem: `depends_on references phase ${d}, which has no manifest entry` })
  }
}
// cycle detection
const visiting = {}, done = {}
const hasCycle = (n) => {
  if (done[n]) return false
  if (visiting[n]) return true
  visiting[n] = true
  for (const d of byNum[n]?.depends_on || []) if (d !== 0 && byNum[d] && hasCycle(d)) return true
  visiting[n] = false; done[n] = true
  return false
}
for (const p of mph) if (hasCycle(p.phase)) { cross.push({ id: `X-cycle-${p.phase}`, severity: 'critical', classification: 'decision-required', location: `manifest phase ${p.phase}`, problem: `dependency cycle reachable from phase ${p.phase}` }); break }

// tiers by longest dependency path
const tierOf = {}
const computeTier = (n) => {
  if (n in tierOf) return tierOf[n]
  const deps = (byNum[n]?.depends_on || []).filter((d) => d !== 0 && byNum[d])
  const t = deps.length ? 1 + Math.max(...deps.map(computeTier)) : (byNum[n]?.depends_on?.includes(0) || !deps.length ? (n === 0 ? 0 : 1) : 0)
  return (tierOf[n] = t)
}
for (const p of mph) computeTier(p.phase)
const tiers = {}
for (const p of mph) (tiers[tierOf[p.phase]] ||= []).push(p.phase)

// sibling file-disjointness, from each phase's reported files_owned
const ownedByPhase = Object.fromEntries(reviews.map((r) => [r.phase, new Set(r.files_owned.map((f) => f.path))]))
const exemptPhases = new Set([0, Math.max(...mph.map((p) => p.phase))]) // Phase 0 + final (legacy-review)
for (const sibs of Object.values(tiers)) {
  for (let i = 0; i < sibs.length; i++)
    for (let j = i + 1; j < sibs.length; j++) {
      const a = ownedByPhase[sibs[i]], b = ownedByPhase[sibs[j]]
      if (!a || !b) continue
      const shared = [...a].filter((f) => b.has(f))
      if (shared.length) cross.push({ id: `X-share-${sibs[i]}-${sibs[j]}`, severity: 'critical', classification: 'decision-required', location: `phases ${sibs[i]} & ${sibs[j]} (same tier — run concurrently)`, problem: `sibling phases share file(s): ${shared.join(', ')}. Concurrent implementers would fight the same lock.` })
    }
  // exempt phases must be alone in their tier
  for (const ph of sibs) if (exemptPhases.has(ph) && sibs.length > 1) cross.push({ id: `X-exempt-${ph}`, severity: 'critical', classification: 'decision-required', location: `phase ${ph}`, problem: `file-overlap-exempt phase ${ph} shares its tier with ${sibs.filter((x) => x !== ph).join(', ')} — it must run alone` })
}

// complexity enum, user_required ids, test_command
if (!manifest.test_command) cross.push({ id: 'X-testcmd', severity: 'major', classification: 'mechanical', location: 'manifest', problem: 'test_command is empty', proposed_fix: "set test_command from the project's CLAUDE.md" })
for (const p of mph)
  for (const w of p.waves || [])
    for (const g of w.task_groups || []) {
      for (const t of g.tasks || []) if (!['S', 'M', 'L'].includes(t.complexity)) cross.push({ id: `X-cx-${t.id}`, severity: 'major', classification: 'mechanical', location: `manifest ${g.group_id}`, problem: `task ${t.id} complexity "${t.complexity}" is not S/M/L` })
      const ids = new Set((g.tasks || []).map((t) => t.id))
      for (const u of g.user_required_tasks || []) if (!ids.has(u)) cross.push({ id: `X-ur-${u}`, severity: 'major', classification: 'mechanical', location: `manifest ${g.group_id}`, problem: `user_required_tasks lists ${u}, not a task in this group` })
    }

log(`deterministic cross-phase checks: ${cross.length} finding(s); tiers: ${JSON.stringify(tiers)}`)

// ── 3. Semantic cross-phase (the only part needing an LLM) ─────────────────────
const semantic = await agent(
  `# Semantic Cross-Phase Spec Check

## Project root: ${project_dir}
## Phase specs in scope
${phases.map((p) => `- Phase ${p.phase} — ${p.name}: ${p.spec_file}`).join('\n')}

Read each spec above and check ONLY the two things deterministic checks cannot:
1. **Duplicate work**: two tasks in different phases that describe the same work under
   different IDs (semantic match, not byte-identical).
2. **Dependency compatibility**: a dependent phase's spec referencing an output (file,
   function, API) that its prerequisite phase does not actually produce, or referencing
   an output from a *later* phase.

Tier structure (from depends_on): ${JSON.stringify(tiers)}.
Return the structured findings object. Empty findings array if none. For each, set
classification to decision-required unless the fix is a single unambiguous edit.`,
  { label: 'cross:semantic', phase: 'Cross-phase', model: 'sonnet', schema: CROSS_SEMANTIC_SCHEMA },
)
if (semantic?.findings) cross.push(...semantic.findings)

return { perPhase: reviews, crossPhase: cross, tiers }
