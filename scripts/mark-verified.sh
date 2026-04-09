#!/usr/bin/env bash

# mark-verified.sh — invoked in-band by the wave-verifier agent as its final
# bash call. Takes the verdict string as its sole positional argument and
# increments verifications_passed / verifications_failed on the current batch.
#
# Usage:
#   bash mark-verified.sh "PASS PASS FAIL"
#
# The verdict argument must be a space-separated list of PASS / FAIL tokens,
# one per task_group, in task_group order.

VERDICT_STRING="$1"

if [ -z "$VERDICT_STRING" ]; then
  echo "mark-verified: ERROR — verdict string argument is required (e.g. \"PASS PASS FAIL\")" >&2
  exit 1
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
  echo "mark-verified: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  exit 1
fi

# --- Parse verdict tokens and update counters ---
result=$(node -e "(() => {
  const fs = require('fs');
  const stateFile = process.argv[1];
  const verdictArg = process.argv[2] || '';

  const tokens = verdictArg.trim().toUpperCase().split(/\\s+/).filter(Boolean);
  const valid = tokens.every(t => t === 'PASS' || t === 'FAIL');
  if (tokens.length === 0 || !valid) {
    console.log('ERROR:Invalid verdict string. Expected space-separated PASS/FAIL tokens.');
    return;
  }

  const newPassed = tokens.filter(t => t === 'PASS').length;
  const newFailed = tokens.filter(t => t === 'FAIL').length;

  const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const batches = s.batches || [];
  const batch = batches.find(b => (b.verifications_passed || 0) < (b.task_groups || []).length);

  if (!batch) {
    console.log('ERROR:No active batch found to update.');
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
})()" "$STATE_FILE" "$VERDICT_STRING" 2>/dev/null || echo "ERROR:node error")

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
    echo "mark-verified: Batch '$batch_id' fully verified ($total_passed/$tg passed)."
  elif [ "$new_failed" != "0" ]; then
    echo "mark-verified: Recorded — $new_passed passed, $new_failed failed ($total_passed/$tg total)."
  else
    echo "mark-verified: Recorded — $new_passed passed ($total_passed/$tg total)."
  fi
  exit 0
fi

echo "mark-verified: $result" >&2
exit 1
