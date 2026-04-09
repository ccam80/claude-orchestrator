#!/usr/bin/env bash

# stop-for-clarification.sh — invoked in-band by an implementer agent when it
# encounters a spec ambiguity it cannot resolve. Increments
# stops_for_clarification on the current active batch.
#
# The counter adds a retry slot via the gate-implementer cap formula, so the
# coordinator can re-spawn a fresh implementer for the same task_group once
# the user has clarified the spec. This script does NOT increment completed —
# the task is not finished, and the verifier must not look at partial work.
#
# Usage:
#   bash stop-for-clarification.sh
#
# Before calling this, the implementer MUST have:
#   1. Released all file locks and its task lock.
#   2. Appended a clarification entry to spec/progress.md that names the
#      task_id, the ambiguity, and any relevant spec references. The
#      coordinator reads this entry verbatim when asking the user.

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
  echo "stop-for-clarification: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  exit 1
fi

# --- Increment stops_for_clarification on current batch ---
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
  batch.stops_for_clarification = (batch.stops_for_clarification || 0) + 1;
  s.last_updated = new Date().toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  console.log(JSON.stringify({
    ok: true,
    batch: batch.id,
    stops_for_clarification: batch.stops_for_clarification
  }));
})()" "$STATE_FILE" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)
  count=$(node -e "console.log(JSON.parse(process.argv[1]).stops_for_clarification)" "$result" 2>/dev/null)
  echo "stop-for-clarification: Recorded on batch '$batch_id' (stops_for_clarification=$count). The coordinator will surface the clarification entry in spec/progress.md to the user."
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "stop-for-clarification: ERROR — $err" >&2
exit 1
