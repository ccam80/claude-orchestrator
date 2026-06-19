#!/usr/bin/env node
// Post-batch scope audit (layer 2). Run by the implement-hybrid / review-orchestrated
// skills after a workflow returns, against the checkpoint commit taken just before the
// workflow ran. The PreToolUse guard (layer 1) prevents deletions during a run; this is
// the backstop that DETECTS anything that slipped through and RECOVERS what is recoverable,
// turning silent data loss into a loud, itemized report.
//
// It compares the working tree to the checkpoint using git (the workflow itself has no
// shell access, so this must run in the skill's main loop), and cross-references the
// per-group file footprint the workflow reported. Three violation classes:
//   - deleted               a file present at checkpoint is now gone        → auto-restore
//   - created-then-deleted  a group reported creating a file that is absent → restore if in
//                           checkpoint, else UNRECOVERABLE (hard error)
//   - modified-out-of-scope a tracked file changed that no group reported   → report only
//                           (never auto-reverted: it may be a legit-but-unreported edit)
//
// Usage:
//   node scope-audit.mjs --checkpoint <sha> --footprint <files.json> [--project <dir>] [--apply]
//
// --footprint points at the workflow's returned `files` map:
//   { "<group_id>": { "created": [...], "modified": [...] }, ... }
// --apply performs restores (git restore --source). Without it, the audit is dry-run.
//
// Output: a JSON report on stdout. Exit 0 = clean, 1 = violations found (recovered or not),
// 2 = at least one UNRECOVERABLE violation (the skill must stop and surface it).

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'

function arg(name, fallback = null) {
  const i = process.argv.indexOf(name)
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback
}
const has = (name) => process.argv.includes(name)

const checkpoint = arg('--checkpoint')
const footprintPath = arg('--footprint')
const projectDir = resolve(arg('--project', process.cwd()))
const apply = has('--apply')

if (!checkpoint || !footprintPath) {
  console.error('usage: scope-audit.mjs --checkpoint <sha> --footprint <files.json> [--project <dir>] [--apply]')
  process.exit(2)
}

function git(args) {
  const r = spawnSync('git', ['-C', projectDir, ...args], { encoding: 'utf8' })
  if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${(r.stderr || '').trim()}`)
  return r.stdout
}
const norm = (p) => p.replace(/\\/g, '/').replace(/^\.\//, '')

// Footprint union across all groups (what agents legitimately reported touching).
const footprint = JSON.parse(readFileSync(footprintPath, 'utf8'))
const owned = new Set()
const reportedCreated = new Set()
for (const g of Object.values(footprint || {})) {
  for (const f of g?.created || []) { owned.add(norm(f)); reportedCreated.add(norm(f)) }
  for (const f of g?.modified || []) owned.add(norm(f))
}

// Tracked changes between the checkpoint and the current working tree.
const diff = git(['diff', '--name-status', '--no-renames', checkpoint, '--'])
const deleted = []
const modified = []
for (const line of diff.split('\n')) {
  if (!line.trim()) continue
  const [status, ...rest] = line.split('\t')
  const path = norm(rest.join('\t'))
  if (status.startsWith('D')) deleted.push(path)
  else if (status.startsWith('M')) modified.push(path)
}

const existsInCheckpoint = (path) =>
  spawnSync('git', ['-C', projectDir, 'cat-file', '-e', `${checkpoint}:${path}`]).status === 0

const violations = []

// 1. Deletions — always a violation during a run; recoverable (the file is in the checkpoint).
for (const path of deleted) {
  const v = { file: path, kind: 'deleted', recovered: false, recoverable: true }
  if (apply) {
    git(['restore', '--source', checkpoint, '--', path])
    v.recovered = true
  }
  violations.push(v)
}

// 2. Created-then-deleted — a group claims it created the file but it is gone from disk.
for (const path of reportedCreated) {
  if (existsSync(resolve(projectDir, path))) continue
  if (deleted.includes(path)) continue // already counted above
  const recoverable = existsInCheckpoint(path)
  const v = { file: path, kind: 'created-then-deleted', recovered: false, recoverable }
  if (recoverable && apply) {
    git(['restore', '--source', checkpoint, '--', path])
    v.recovered = true
  }
  violations.push(v)
}

// 3. Out-of-scope modifications — a tracked file changed that no group reported owning.
//    Reported only; never auto-reverted (it may be a real edit the agent failed to list).
for (const path of modified) {
  if (owned.has(path)) continue
  violations.push({ file: path, kind: 'modified-out-of-scope', recovered: false, recoverable: true })
}

const unrecoverable = violations.filter((v) => !v.recoverable && !v.recovered)
const report = {
  clean: violations.length === 0,
  applied: apply,
  checkpoint,
  counts: {
    deleted: violations.filter((v) => v.kind === 'deleted').length,
    created_then_deleted: violations.filter((v) => v.kind === 'created-then-deleted').length,
    modified_out_of_scope: violations.filter((v) => v.kind === 'modified-out-of-scope').length,
  },
  violations,
  unrecoverable,
}
console.log(JSON.stringify(report, null, 2))
process.exit(report.clean ? 0 : unrecoverable.length ? 2 : 1)
