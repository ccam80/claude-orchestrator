export const meta = {
  name: 'co-review',
  description: 'Fan out one reviewer per completed phase; return structured findings for the auto-fix ruleset',
  phases: [{ title: 'Review', detail: 'one reviewer agent per phase, concurrently' }],
}

// ── args contract (passed by the review-orchestrated skill) ───────────────────
//   project_dir   absolute project root
//   plugin_root   absolute plugin root (for references/)
//   phases: [{ phase, name, spec_file }]   // phases with completed work in scope
const _args = typeof args === 'string' ? JSON.parse(args) : args
const { project_dir, plugin_root, phases } = _args

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['phase', 'verdict', 'findings'],
  properties: {
    phase: { type: 'number' },
    verdict: { enum: ['clean', 'has-violations'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'category', 'severity', 'file', 'evidence', 'fix_hint'],
        properties: {
          id: { type: 'string' },
          category: { enum: ['violation', 'gap', 'weak-test', 'legacy'] },
          severity: { enum: ['critical', 'major', 'minor'] },
          file: { type: 'string' },
          line: { type: 'number' },
          rule: { type: 'string' },
          evidence: { type: 'string' },
          fix_hint: { type: 'string' },
        },
      },
    },
  },
}

const reviewerPrompt = (p) => `# Phase Review Assignment

## Project
- **Root**: ${project_dir}
- **Phase spec file**: ${p.spec_file}
- **Rules file**: ${plugin_root}/references/rules.md
- **Progress file**: ${project_dir}/spec/progress.md (source of truth for file lists)
- **Report path**: ${project_dir}/spec/reviews/phase-${p.phase}.md

## Review scope: Phase ${p.phase} — ${p.name}
Audit every completed task for this phase against its spec, the rules, and test quality.

## Before anything else, read
- ${plugin_root}/references/rules.md — rules to check against
- ${p.spec_file} — task specifications
- ${project_dir}/CLAUDE.md — project conventions
- ${project_dir}/spec/progress.md — what was implemented (file lists)

Write your full human-readable report to the report path above, then return the
REVIEW_RESULT structured object (every individual finding, never aggregated).`

phase('Review')
const results = await parallel(
  phases.map((p) => () =>
    agent(reviewerPrompt(p), {
      label: `review:phase-${p.phase}`,
      phase: 'Review',
      agentType: 'claude-orchestrator:reviewer',
      model: 'sonnet',
      schema: REVIEW_SCHEMA,
    }),
  ),
)

const perPhase = results.filter(Boolean)
log(`reviewed ${perPhase.length}/${phases.length} phases; ${perPhase.reduce((n, r) => n + r.findings.length, 0)} findings`)

return { perPhase }
