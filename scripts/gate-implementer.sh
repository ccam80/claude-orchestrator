#!/usr/bin/env bash

# gate-implementer.sh — PreToolUse hook for claude-orchestrator:implementer
# Blocks implementer spawns when any batch has completed but not been verified.
#
# Registered via implement-hybrid SKILL.md frontmatter with:
#   if: "Agent(claude-orchestrator:implementer)"
# So this script only runs for implementer agent spawns — no filtering needed.
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow the tool call
#   exit 2 — block the tool call (stdout shown to agent as reason)

# --- Locate the state file (cheap bash check) ---
STATE_FILE=""
dir="$PWD"
while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -f "$dir/spec/.hybrid-state.json" ]; then
    STATE_FILE="$dir/spec/.hybrid-state.json"
    break
  fi
  dir=$(dirname "$dir")
done

# No state file → first batch, nothing to gate
if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# Drain stdin (hook contract requires reading it even if unused)
cat > /dev/null

# --- Check for unverified completed batches ---
# A batch blocks if: verified=false AND status is NOT "implementing"
# (implementing means the batch is still in-flight — those are allowed)
blocked_batch=$(node -e "
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const batches = s.batches || [];
  const blocker = batches.find(b => !b.verified && b.status !== 'implementing');
  if (blocker) {
    console.log(JSON.stringify({ id: blocker.id, status: blocker.status, waves: blocker.waves }));
  } else {
    console.log('');
  }
" "$STATE_FILE" 2>/dev/null)

if [ -z "$blocked_batch" ]; then
  exit 0
fi

# Extract fields for the error message
batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).id)" "$blocked_batch" 2>/dev/null)
batch_status=$(node -e "console.log(JSON.parse(process.argv[1]).status)" "$blocked_batch" 2>/dev/null)
batch_waves=$(node -e "console.log(JSON.parse(process.argv[1]).waves.join(', '))" "$blocked_batch" 2>/dev/null)

echo "BLOCKED: Batch '$batch_id' (waves: $batch_waves) has status='$batch_status' and is not verified."
echo ""
echo "You must verify this batch before spawning new implementers."
echo "Spawn a wave-verifier agent for this batch:"
echo "  subagent_type: claude-orchestrator:wave-verifier"
echo "  Include the batch ID, wave/task list, phase spec path, and test command in the prompt."
echo ""
echo "The PostToolUse hook on the wave-verifier will set verified=true ONLY if the verifier returns PASS."
echo "If the verifier returns FAIL, read the Failure Summary and spawn fix agents before re-verifying."
echo ""
echo "State file: $STATE_FILE"
exit 2
