export const meta = {
  name: 'co-apply-fixes',
  description: 'Fan out one fix-agent per target file/cluster to apply a pre-resolved edit list, optionally run tests',
  phases: [{ title: 'Fix', detail: 'one fix-agent per file cluster, concurrently' }],
}

// ── args contract (passed by review-orchestrated / review-spec skills) ────────
//   project_dir, plugin_root
//   test_command   optional — if set, each code-fix cluster runs it
//   baseline_file  optional — path to spec/test-baseline.md
//   clusters: [{
//     targets: [filePath],                 // the only files this fix-agent may edit
//     run_tests: bool,                     // run test_command after edits
//     edits: [{ id, source, file, old_string?, new_string?, directive?, report_hint? }]
//   }]
const _args = typeof args === 'string' ? JSON.parse(args) : args
const { project_dir, plugin_root, test_command, baseline_file, clusters } = _args

const FIX_SCHEMA = {
  type: 'object',
  required: ['files_edited', 'edits', 'scope_mismatches'],
  properties: {
    files_edited: { type: 'array', items: { type: 'string' } },
    files_read_unchanged: { type: 'array', items: { type: 'string' } },
    edits: {
      type: 'array',
      items: {
        type: 'object',
        required: ['source', 'file', 'summary'],
        properties: { source: { type: 'string' }, file: { type: 'string' }, summary: { type: 'string' } },
      },
    },
    discoveries: { type: 'array', items: { type: 'string' } },
    rule_violations_fixed: { type: 'array', items: { type: 'string' } },
    preexisting_noted: { type: 'array', items: { type: 'string' } },
    scope_mismatches: {
      type: 'array',
      items: {
        type: 'object',
        required: ['edit', 'file', 'reason'],
        properties: { edit: { type: 'string' }, file: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    test_results: {
      type: 'object',
      properties: { passing: { type: 'number' }, total: { type: 'number' }, new_failures: { type: 'array', items: { type: 'string' } } },
    },
  },
}

function fixPrompt(c) {
  const editLines = c.edits
    .map((e) => {
      const head = `- [${e.id}] (${e.source}) in \`${e.file}\``
      if (e.old_string != null) return `${head}\n    OLD: ${JSON.stringify(e.old_string)}\n    NEW: ${JSON.stringify(e.new_string)}`
      return `${head}\n    DIRECTIVE: ${e.directive}${e.report_hint ? `\n    REPORT: ${e.report_hint}` : ''}`
    })
    .join('\n')
  const testBlock = c.run_tests && test_command
    ? `\n## Test directive\nAfter edits, run: ${test_command}\nBaseline (pre-existing failures): ${baseline_file || 'none provided'}. Report new failures vs baseline; do NOT revert on regression — report it.\n`
    : ''
  return `# Fix Assignment

## Project
- **Root**: ${project_dir}
- **Rules file**: ${plugin_root}/references/rules.md

## Target files (you may edit ONLY these)
${c.targets.map((t) => `- ${t}`).join('\n')}

## Edits to apply (in order)
${editLines}
${testBlock}
## Before editing, read
- ${plugin_root}/references/rules.md — every edit must comply
- ${project_dir}/CLAUDE.md — project conventions
- each target file in full

Return the FIX_RESULT structured object. If any edit cannot be applied (file not in the
target list, ambiguous directive, old_string missing), list it under scope_mismatches and
do not improvise.`
}

phase('Fix')
const reports = await parallel(
  clusters.map((c, i) => () =>
    agent(fixPrompt(c), {
      label: `fix:${c.targets[0] || i}`,
      phase: 'Fix',
      agentType: 'claude-orchestrator:fix-agent',
      model: 'sonnet',
      schema: FIX_SCHEMA,
    }),
  ),
)

const applied = reports.filter(Boolean)
const mismatches = applied.flatMap((r) => r.scope_mismatches)
log(`fix clusters: ${applied.length}/${clusters.length}; scope mismatches: ${mismatches.length}`)

return { reports: applied, mismatches }
