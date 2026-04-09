#!/usr/bin/env bash

# gate-implementer.sh — PreToolUse hook for claude-orchestrator:implementer
# Counter-based gate: checks spawn conditions, increments spawned on allow.
#
# Spawn conditions (ALL must be true):
#   1. spawned < len(task_groups) + verifications_failed
#   2. verifications_passed + verifications_failed >= completed
#
# Filters by subagent_type internally (if field can't handle colons).
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow
#   exit 2 — block (stdout shown to agent)

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

  // Current batch = first where verifications_passed < task_groups count
  const batch = batches.find(b => (b.verifications_passed || 0) < (b.task_groups || []).length);
  if (!batch) {
    console.log('ALLOW');
    return;
  }

  const tg = (batch.task_groups || []).length;
  const spawned = batch.spawned || 0;
  const completed = batch.completed || 0;
  const passed = batch.verifications_passed || 0;
  const failed = batch.verifications_failed || 0;

  // Condition 1: haven't exceeded slots (initial + retries)
  if (spawned >= tg + failed) {
    console.log('BLOCK:' + JSON.stringify({
      id: batch.id, reason: 'spawn_cap',
      spawned: spawned, cap: tg + failed, task_groups: tg, failed: failed
    }));
    return;
  }

  // Condition 2: all completed work must be reviewed before spawning more
  if (completed > 0 && (passed + failed) < completed) {
    console.log('BLOCK:' + JSON.stringify({
      id: batch.id, reason: 'unreviewed_work',
      completed: completed, reviewed: passed + failed
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
  echo "BLOCKED: Batch '$batch_id' — all implementer slots used (spawned=$spawned, cap=$cap). Spawn a wave-verifier to verify completed work. Failed verifications add retry slots." >&2
elif [ "$reason" = "unreviewed_work" ]; then
  completed=$(node -e "console.log(JSON.parse(process.argv[1]).completed)" "$info" 2>/dev/null)
  reviewed=$(node -e "console.log(JSON.parse(process.argv[1]).reviewed)" "$info" 2>/dev/null)
  echo "BLOCKED: Batch '$batch_id' — completed implementations ($completed) exceed reviews ($reviewed). Spawn a wave-verifier before spawning more implementers." >&2
fi
echo "State file: $STATE_FILE" >&2
exit 2
