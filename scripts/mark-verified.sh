#!/usr/bin/env bash

# mark-verified.sh — SubagentStop hook for claude-orchestrator:wave-verifier
# Parses per-task-group verdicts from the verifier's final assistant message,
# and increments verifications_passed / verifications_failed counters.
#
# SubagentStop input:
#   stdin — JSON with { agent_type, last_assistant_message, ... }
#   exit 0 — always (this event cannot block)
#
# Expected verifier output format:
#   ## Verdict: PASS PASS FAIL
# (space-separated, one per task_group in order)

# --- Read stdin, filter by agent_type ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

is_verifier=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const t = j.agent_type || '';
  console.log(t === 'claude-orchestrator:wave-verifier' ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_verifier" != "yes" ]; then
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

# --- Parse per-group verdicts and update counters ---
result=$(node -e "(() => {
  const fs = require('fs');
  const input = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const stateFile = process.argv[2];

  const msg = input.last_assistant_message || '';
  const match = msg.match(/##\\s*Verdict:\\s*((?:PASS|FAIL)(?:\\s+(?:PASS|FAIL))*)/i);

  if (!match) {
    console.log('WARNING:Could not parse verdict line from verifier output.');
    return;
  }

  const verdicts = match[1].toUpperCase().split(/\\s+/);
  const newPassed = verdicts.filter(v => v === 'PASS').length;
  const newFailed = verdicts.filter(v => v === 'FAIL').length;

  const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const batches = s.batches || [];
  const batch = batches.find(b => (b.verifications_passed || 0) < (b.task_groups || []).length);

  if (!batch) {
    console.log('WARNING:No active batch found to update.');
    return;
  }

  batch.verifications_passed = (batch.verifications_passed || 0) + newPassed;
  batch.verifications_failed = (batch.verifications_failed || 0) + newFailed;
  s.last_updated = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));

  const tg = (batch.task_groups || []).length;
  const totalPassed = batch.verifications_passed;
  const done = totalPassed >= tg;

  console.log('OK:' + JSON.stringify({
    batch: batch.id,
    new_passed: newPassed,
    new_failed: newFailed,
    total_passed: totalPassed,
    total_failed: batch.verifications_failed,
    task_groups: tg,
    batch_complete: done
  }));
})()" "$TMPINPUT" "$STATE_FILE" 2>/dev/null || echo "WARNING:node error")

action=$(echo "$result" | cut -d: -f1)

if [ "$action" = "OK" ]; then
  info=$(echo "$result" | cut -d: -f2-)
  new_passed=$(node -e "console.log(JSON.parse(process.argv[1]).new_passed)" "$info" 2>/dev/null)
  new_failed=$(node -e "console.log(JSON.parse(process.argv[1]).new_failed)" "$info" 2>/dev/null)
  total_passed=$(node -e "console.log(JSON.parse(process.argv[1]).total_passed)" "$info" 2>/dev/null)
  tg=$(node -e "console.log(JSON.parse(process.argv[1]).task_groups)" "$info" 2>/dev/null)
  batch_complete=$(node -e "console.log(JSON.parse(process.argv[1]).batch_complete)" "$info" 2>/dev/null)
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$info" 2>/dev/null)

  if [ "$batch_complete" = "true" ]; then
    echo "hook success: Batch '$batch_id' fully verified ($total_passed/$tg passed). Proceed to next batch."
  elif [ "$new_failed" != "0" ]; then
    echo "hook success: Verification recorded — $new_passed passed, $new_failed failed ($total_passed/$tg total). Spawn fix implementers for failed groups, then re-verify."
  else
    echo "hook success: Verification recorded — $new_passed passed ($total_passed/$tg total)."
  fi
else
  echo "hook success: $result"
fi

exit 0
