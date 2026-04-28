#!/usr/bin/env bash

# gate-implementer.sh — PreToolUse hook for claude-orchestrator:implementer
# Counter-based gate: checks the spawn cap, increments spawned on allow.
#
# Spawn condition:
#   spawned < len(task_groups) + verifications_failed
#                              + stops_for_clarification
#                              + dead_implementers
#
# The coordinator may spawn implementers (initial work, dead-agent retries,
# clarification retries, failed-verification retries) freely up to this cap.
# Verification happens once at the end of a batch — the gate does NOT block
# implementer spawns on unreviewed completed work.
#
# Filters by subagent_type internally.
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow (silent: no stdout, no stderr)
#   exit 2 — block, block reason on STDERR (Claude Code surfaces stderr on exit 2)

# --- Locate state file (cheap bash check first) ---
STATE_FILE=""
dir="$PWD"
while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -f "$dir/spec/.hybrid-state.json" ]; then
    STATE_FILE="$dir/spec/.hybrid-state.json"
    break
  fi
  dir=$(dirname "$dir")
done

if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# --- Read stdin, filter by subagent_type ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

is_implementer=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const st = (j.tool_input && j.tool_input.subagent_type) || '';
  console.log(st === 'claude-orchestrator:implementer' ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_implementer" != "yes" ]; then
  exit 0
fi

# --- Find current batch and check conditions ---
result=$(node -e "(() => {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const batches = s.batches || [];

  const isBatchDone = (b) => {
    const gs = b.group_status || {};
    const groups = b.task_groups || [];
    return groups.length > 0 && groups.every(g => gs[g] === 'passed');
  };
  const batch = batches.find(b => !isBatchDone(b));
  if (!batch) {
    console.log('ALLOW');
    return;
  }

  const tg = (batch.task_groups || []).length;
  const spawned = batch.spawned || 0;
  const failed = batch.verifications_failed || 0;
  const clarif = batch.stops_for_clarification || 0;
  const dead = batch.dead_implementers || 0;
  const cap = tg + failed + clarif + dead;

  // Spawn cap: initial slots + retries from failures, clarification stops,
  // and dead implementers. The coordinator may fill the batch (including
  // dead-agent retries) before any verification has happened.
  if (spawned >= cap) {
    console.log('BLOCK:' + JSON.stringify({
      id: batch.id, reason: 'spawn_cap',
      spawned, cap, task_groups: tg, failed,
      stops_for_clarification: clarif, dead_implementers: dead
    }));
    return;
  }

  // Allowed — increment spawned counter
  batch.spawned = spawned + 1;
  s.last_updated = new Date().toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  console.log('ALLOW');
})()" "$STATE_FILE" 2>/dev/null || echo "ALLOW:error")

action=$(echo "$result" | cut -d: -f1)

if [ "$action" = "ALLOW" ]; then
  exit 0
fi

# --- Blocked — extract reason and report to stderr ---
info=$(echo "$result" | cut -d: -f2-)
batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).id)" "$info" 2>/dev/null)
reason=$(node -e "console.log(JSON.parse(process.argv[1]).reason)" "$info" 2>/dev/null)

if [ "$reason" = "spawn_cap" ]; then
  spawned=$(node -e "console.log(JSON.parse(process.argv[1]).spawned)" "$info" 2>/dev/null)
  cap=$(node -e "console.log(JSON.parse(process.argv[1]).cap)" "$info" 2>/dev/null)
  echo "BLOCKED: Batch '$batch_id' — all implementer slots used (spawned=$spawned, cap=$cap). If every group has a finished implementer, spawn wave-verifiers (one per 4 task_groups). Failed verifications, clarification stops, and dead implementers each add retry slots." >&2
fi
echo "State file: $STATE_FILE" >&2
exit 2
