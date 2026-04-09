#!/usr/bin/env bash

# complete-implementer.sh — SubagentStop hook for claude-orchestrator:implementer
# Increments the completed counter on the current batch when an implementer finishes.
#
# SubagentStop input:
#   stdin — JSON with { agent_type, last_assistant_message, ... }
#   exit 0 — always (this event cannot block)
#
# We filter by agent_type inside the script; the PostToolUse-era bug where
# the hook fired at spawn-time (tool_response empty) does not apply here —
# SubagentStop fires only after the subagent has fully finished.

# --- Read stdin, filter by agent_type ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

is_implementer=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const t = j.agent_type || '';
  console.log(t === 'claude-orchestrator:implementer' ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_implementer" != "yes" ]; then
  exit 0
fi

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
