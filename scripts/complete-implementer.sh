#!/usr/bin/env bash

# complete-implementer.sh — invoked in-band by the implementer agent as its
# final bash call (see agents/implementer.md step 8). Increments the
# completed counter on the current active batch.
#
# Usage: bash complete-implementer.sh
#
# If an implementer is stopping because the spec is ambiguous rather than
# because its task is finished, call scripts/stop-for-clarification.sh
# instead — that path opens a retry slot without marking work as completed,
# so the verifier will not try to check work that does not exist.

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
  echo "complete-implementer: WARNING — no spec/.hybrid-state.json found walking up from $PWD." >&2
  echo "complete-implementer: This script is only meaningful inside an implement-hybrid run. If you are inside a hybrid batch and seeing this message, the implementer's working directory has drifted or the state file was deleted — the coordinator will not see this completion and the batch will stall. If you are NOT inside a hybrid run (e.g. you are a fix-agent invoked by review-orchestrated), you should not be calling this script at all; remove the call." >&2
  exit 0
fi

# --- Increment completed counter on current active batch ---
node -e "(() => {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const batches = s.batches || [];
  const isBatchDone = (b) => {
    const gs = b.group_status || {};
    const groups = b.task_groups || [];
    return groups.length > 0 && groups.every(g => gs[g] === 'passed');
  };
  const batch = batches.find(b => !isBatchDone(b));
  if (batch) {
    batch.completed = (batch.completed || 0) + 1;
    s.last_updated = new Date().toISOString();
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  }
})()" "$STATE_FILE" 2>/dev/null

exit 0
