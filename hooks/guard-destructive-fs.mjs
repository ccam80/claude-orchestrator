#!/usr/bin/env node
// PreToolUse guard: deny destructive filesystem / git commands while an orchestrated
// run is active. The implement-hybrid and review-orchestrated skills drop a sentinel
// (.omc/state/co-guard-active) for the duration of a run; outside a run this hook is a
// no-op, so it never interferes with the user's normal interactive shell.
//
// Rationale: parallel implementer / fix / fix-agent subagents share one working tree.
// A fix-implementer chasing a test failure once `rm`-ed another agent's freshly created
// files. Prose rules ("never delete", "never git checkout") could not stop it because
// nothing enforced them. This makes the ban mechanical: the deletion verb is refused
// before it runs, for every agent, in the one window where cross-contamination is possible.

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

function allow() {
  // No output + exit 0 = the tool call proceeds unchanged.
  process.exit(0)
}

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    }),
  )
  process.exit(0)
}

// ── read the hook payload ─────────────────────────────────────────────────────
let payload
try {
  payload = JSON.parse(readFileSync(0, 'utf8'))
} catch {
  allow() // malformed payload: fail open — layer 2 (git audit) is the backstop.
}

if (!payload || payload.tool_name !== 'Bash') allow()

const command = payload.tool_input && payload.tool_input.command
if (typeof command !== 'string' || !command.trim()) allow()

// ── only enforce while an orchestrated run is active ──────────────────────────
const cwd = payload.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd()
const sentinel = join(cwd, '.omc', 'state', 'co-guard-active')
if (!existsSync(sentinel)) allow()

// ── classify each command segment ─────────────────────────────────────────────
// Split on shell sequencing/pipes so `mkdir x && rm -rf y` is checked segment-by-segment,
// and strip leading `sudo`/`time`/`env VAR=val` noise before reading the verb.
function segments(cmd) {
  return cmd
    .split(/&&|\|\||[|;\n]/)
    .map((s) => s.trim())
    .filter(Boolean)
}

function stripPrefix(seg) {
  let s = seg.replace(/^\s*(sudo|command|time|nice|nohup)\s+/i, '')
  // drop inline env assignments: FOO=bar BAZ=qux rm ...
  s = s.replace(/^(\s*[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)+/, '')
  return s.trim()
}

// Returns a human-readable reason string if the segment is destructive, else null.
function classify(rawSeg) {
  const seg = stripPrefix(rawSeg)

  // POSIX deletion verbs at the head of the segment.
  if (/^(rm|unlink|rmdir|shred)\b/i.test(seg))
    return `\`${seg.split(/\s+/)[0]}\` deletes files`
  // Windows / PowerShell deletion verbs.
  if (/^(del|erase|rd|Remove-Item|ri)\b/i.test(seg))
    return `\`${seg.split(/\s+/)[0]}\` deletes files`
  // find ... -delete  and  ... xargs rm ...
  if (/\bfind\b[\s\S]*\s-delete\b/i.test(seg)) return '`find -delete` deletes files'
  if (/\bxargs\b[\s\S]*\brm\b/i.test(seg)) return '`xargs rm` deletes files'

  // git subcommands that discard or remove work in the tree.
  const git = seg.match(/^git\s+(\w[\w-]*)/i)
  if (git) {
    const sub = git[1].toLowerCase()
    if (sub === 'clean') return '`git clean` removes untracked files (other agents may own them)'
    if (sub === 'checkout') return '`git checkout` discards or switches working-tree changes'
    if (sub === 'stash') return '`git stash` hides working-tree changes'
    if (sub === 'rm') return '`git rm` deletes tracked files'
    if (sub === 'reset' && /\s--(hard|merge|keep)\b/i.test(seg))
      return '`git reset --hard/--merge/--keep` discards working-tree changes'
  }
  return null
}

for (const seg of segments(command)) {
  const reason = classify(seg)
  if (reason) {
    deny(
      `Blocked by claude-orchestrator scope guard: ${reason}. An orchestrated run is active, ` +
        `so destructive filesystem/git commands are refused — parallel agents share this working ` +
        `tree and you may be about to destroy another agent's work. To remove code from a file you ` +
        `own, edit it with the Edit tool. If a file genuinely must be deleted, that is a coordinator ` +
        `decision: report it in your structured result instead of deleting it here. (git add/commit ` +
        `and git restore --source remain allowed for the coordinator's checkpoint/recovery.)`,
    )
  }
}

allow()
