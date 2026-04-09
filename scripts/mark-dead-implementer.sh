#!/usr/bin/env bash

# mark-dead-implementer.sh — invoked by the implement-hybrid coordinator when
# it has positive evidence that an implementer subagent died mid-output
# without running complete-implementer.sh. Increments dead_implementers on
# the current active batch, which opens a retry slot via the gate-implementer
# cap formula. Does NOT increment completed, so the verifier will not try to
# check work that was never finished.
#
# Usage:
#   bash mark-dead-implementer.sh
#
# Call ONLY when you have positive evidence the subagent is dead — e.g. its
# TaskOutput returned completed/failed but the counters did not advance.
# Never call speculatively while an agent is still running.

# --- Locate state file ---
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
  echo "mark-dead-implementer: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  exit 1
fi

# --- Increment dead_implementers on current batch ---
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
    console.log(JSON.stringify({ok: false, error: 'No active batch found.'}));
    return;
  }
  batch.dead_implementers = (batch.dead_implementers || 0) + 1;
  s.last_updated = new Date().toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  console.log(JSON.stringify({
    ok: true,
    batch: batch.id,
    dead_implementers: batch.dead_implementers
  }));
})()" "$STATE_FILE" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)
  count=$(node -e "console.log(JSON.parse(process.argv[1]).dead_implementers)" "$result" 2>/dev/null)
  echo "mark-dead-implementer: Recorded on batch '$batch_id' (dead_implementers=$count). A retry slot is now available — spawn a fresh implementer for the affected task_group."
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "mark-dead-implementer: ERROR — $err" >&2
exit 1
