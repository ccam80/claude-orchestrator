#!/usr/bin/env bash

# complete-implementer.sh — Stop hook registered via agents/implementer.md frontmatter
# Fires only inside the implementer agent's own context, so no agent_type filter
# is needed. Increments the completed counter on the current batch.
#
# Stop hook input:
#   stdin — JSON (we do not need to read it)
#   exit 0 — always (this event cannot block)

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
  exit 0
fi

# --- Increment completed counter on current batch ---
node -e "(() => {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const batches = s.batches || [];
  const batch = batches.find(b => (b.verifications_passed || 0) < (b.task_groups || []).length);
  if (batch) {
    batch.completed = (batch.completed || 0) + 1;
    s.last_updated = new Date().toISOString();
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  }
})()" "$STATE_FILE" 2>/dev/null

exit 0
