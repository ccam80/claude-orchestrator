#!/usr/bin/env bash

# mark-verified.sh — PostToolUse hook for Agent tool
# Parses the wave-verifier's output. Sets verified=true for the current batch
# ONLY if the verifier returned "## Verdict: PASS". On FAIL, injects context
# telling the coordinator what to fix.
#
# Registered via implement-hybrid SKILL.md frontmatter (matcher: Agent).
# The `if` field cannot filter by subagent_type (colons break the pattern),
# so this script filters internally via tool_input.subagent_type.
#
# Hook contract (PostToolUse):
#   stdin  — JSON with { tool_name, tool_input, tool_response }
#   stdout — optional context for the agent
#   exit 0 — always (PostToolUse cannot block, tool already ran)

# --- Read hook input ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

# --- Filter by subagent_type — only act on wave-verifier ---
is_verifier=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const st = (j.tool_input && j.tool_input.subagent_type) || '';
  console.log(st === 'claude-orchestrator:wave-verifier' ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_verifier" != "yes" ]; then
  exit 0
fi

# --- Locate the state file ---
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

# --- Extract verdict from verifier output ---
# The wave-verifier returns markdown with "## Verdict: PASS" or "## Verdict: FAIL"
# Check tool_response for the verdict line
verdict=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  // tool_response may be a string or an object with a result field
  const resp = typeof j.tool_response === 'string'
    ? j.tool_response
    : JSON.stringify(j.tool_response || '');
  const match = resp.match(/##\\s*Verdict:\\s*(PASS|FAIL)/i);
  console.log(match ? match[1].toUpperCase() : 'UNKNOWN');
" "$TMPINPUT" 2>/dev/null || echo "UNKNOWN")

if [ "$verdict" = "PASS" ]; then
  # --- Find the batch in 'verifying' status and mark it verified ---
  node -e "
    const fs = require('fs');
    const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const batches = s.batches || [];
    const batch = batches.find(b => b.status === 'verifying');
    if (batch) {
      batch.verified = true;
      batch.status = 'verified';
      s.last_updated = new Date().toISOString();
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    }
  " "$STATE_FILE" 2>/dev/null

  # Inject context telling coordinator the batch is now verified
  echo "hook success: Wave verification PASSED. Batch marked verified=true. You may proceed to the next batch."

elif [ "$verdict" = "FAIL" ]; then
  # --- Mark the batch as failed (not verified) ---
  node -e "
    const fs = require('fs');
    const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const batches = s.batches || [];
    const batch = batches.find(b => b.status === 'verifying');
    if (batch) {
      batch.verified = false;
      batch.status = 'failed';
      s.last_updated = new Date().toISOString();
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    }
  " "$STATE_FILE" 2>/dev/null

  # Inject context telling coordinator what to do
  echo "hook success: Wave verification FAILED. Batch marked status=failed, verified=false."
  echo "Read the verifier's Failure Summary for specific issues. Spawn fix agents to address them, then re-verify."
  echo "The implementer gate will block until this batch is verified."

else
  # Verdict not parseable — do not set any flags, force manual intervention
  echo "hook success: WARNING — Could not parse verifier verdict (got '$verdict'). State unchanged."
  echo "Check the verifier output manually. The batch remains unverified."
fi

exit 0
