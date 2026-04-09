#!/usr/bin/env bash

# gate-verifier.sh — PreToolUse hook for claude-orchestrator:wave-verifier
# Blocks verifier spawns when there's nothing new to verify.
#
# Spawn conditions (ALL must be true):
#   1. at least one task_group is not yet "passed" in group_status
#   2. completed > verifications_passed + verifications_failed (unreviewed work exists)
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow (silent: no stdout, no stderr)
#   exit 2 — block, block reason on STDERR (Claude Code surfaces stderr on exit 2)

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
  const isBatchDone = (b) => {
    const gs = b.group_status || {};
    const groups = b.task_groups || [];
    return groups.length > 0 && groups.every(g => gs[g] === 'passed');
  };
  const batch = batches.find(b => !isBatchDone(b));
  if (!batch) {
    console.log('BLOCK:all_batches_verified');
    return;
  }

  const completed = batch.completed || 0;
  const passed = batch.verifications_passed || 0;
  const failed = batch.verifications_failed || 0;

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

echo "BLOCKED: Cannot spawn verifier — $result" >&2
echo "State file: $STATE_FILE" >&2
exit 2
