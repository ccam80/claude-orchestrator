#!/usr/bin/env bash

# gate-verifier.sh — PreToolUse hook for claude-orchestrator:wave-verifier
# Blocks verifier spawns when there's nothing new to verify.
#
# Spawn conditions (ALL must be true):
#   1. verifications_passed < len(task_groups)  (not fully verified yet)
#   2. completed > verifications_passed + verifications_failed  (unreviewed work exists)
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow
#   exit 2 — block

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

# --- Read stdin, filter by subagent_type ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

is_verifier=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const st = (j.tool_input && j.tool_input.subagent_type) || '';
  console.log(st === 'claude-orchestrator:wave-verifier' ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_verifier" != "yes" ]; then
  exit 0
fi

# --- Check conditions ---
result=$(node -e "(() => {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const batches = s.batches || [];
  const batch = batches.find(b => (b.verifications_passed || 0) < (b.task_groups || []).length);
  if (!batch) {
    console.log('BLOCK:all_batches_verified');
    return;
  }

  const tg = (batch.task_groups || []).length;
  const completed = batch.completed || 0;
  const passed = batch.verifications_passed || 0;
  const failed = batch.verifications_failed || 0;

  // Condition 1: not fully verified
  if (passed >= tg) {
    console.log('BLOCK:batch_done:' + batch.id);
    return;
  }

  // Condition 2: there must be unreviewed completed work
  if (completed <= passed + failed) {
    console.log('BLOCK:nothing_to_verify:' + batch.id + ':completed=' + completed + ':reviewed=' + (passed + failed));
    return;
  }

  console.log('ALLOW');
})()" "$STATE_FILE" 2>/dev/null || echo "ALLOW")

action=$(echo "$result" | cut -d: -f1)

if [ "$action" = "ALLOW" ]; then
  exit 0
fi

echo "BLOCKED: Cannot spawn verifier — $result"
echo "State file: $STATE_FILE"
exit 2
