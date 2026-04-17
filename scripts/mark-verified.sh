#!/usr/bin/env bash

# mark-verified.sh — invoked in-band by the wave-verifier agent as its final
# bash call. Takes a JSON verdict map (single positional arg) and updates the
# per-task-group status on the active batch in spec/.hybrid-state.json.
#
# Usage:
#   bash mark-verified.sh '{"0.1.a":"PASS","0.1.c":"FAIL"}'
#
# The map keys are task_group IDs; values are PASS or FAIL. Only include
# task_groups this verifier run actually verified. Do NOT pad the map with
# PASS entries for already-passed groups — the script rejects entries for
# task_groups whose current status is already "passed".

VERDICT_ARG="$1"

if [ -z "$VERDICT_ARG" ]; then
  echo "mark-verified: ERROR — verdict map argument is required (e.g. '{\"0.1.a\":\"PASS\"}')" >&2
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

# --- Parse verdict map and update per-group status ---
result=$(node -e "(() => {
  const fs = require('fs');
  const stateFile = process.argv[1];
  const verdictArg = process.argv[2];
  const out = (obj) => console.log(JSON.stringify(obj));

  let verdict;
  try {
    verdict = JSON.parse(verdictArg);
  } catch (e) {
    out({ok: false, error: 'Invalid JSON verdict map: ' + e.message});
    return;
  }
  if (!verdict || typeof verdict !== 'object' || Array.isArray(verdict)) {
    out({ok: false, error: 'Verdict must be a JSON object mapping task_group IDs to PASS or FAIL.'});
    return;
  }

  const entries = Object.entries(verdict);
  if (entries.length === 0) {
    out({ok: false, error: 'Verdict map is empty — pass at least one task_group verdict.'});
    return;
  }
  for (const [key, val] of entries) {
    if (val !== 'PASS' && val !== 'FAIL') {
      out({ok: false, error: 'Task_group ' + JSON.stringify(key) + ' has invalid verdict ' +
        JSON.stringify(val) + ' — must be PASS or FAIL.'});
      return;
    }
  }

  const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const batches = s.batches || [];
  const isBatchDone = (b) => {
    const gs = b.group_status || {};
    const groups = b.task_groups || [];
    return groups.length > 0 && groups.every(g => gs[g] === 'passed');
  };
  const batch = batches.find(b => !isBatchDone(b));

  if (!batch) {
    out({ok: false, error: 'No active batch found to update.'});
    return;
  }

  // Initialise group_status if missing (backward compat with pre-upgrade state).
  if (!batch.group_status) {
    batch.group_status = {};
    for (const g of (batch.task_groups || [])) {
      batch.group_status[g] = 'pending';
    }
  }

  // Validate every verdict entry before applying any.
  const batchGroups = new Set(batch.task_groups || []);
  const userRequired = batch.user_required_tasks || {};
  const userAcks = batch.user_acks || {};
  for (const [key, val] of entries) {
    if (!batchGroups.has(key)) {
      out({ok: false, error: 'Task_group ' + JSON.stringify(key) + ' is not in batch ' +
        JSON.stringify(batch.id) + '. Known groups: ' + JSON.stringify([...batchGroups])});
      return;
    }
    const current = batch.group_status[key] || 'pending';
    if (current === 'passed') {
      out({ok: false, error: 'Task_group ' + JSON.stringify(key) + ' is already passed on batch ' +
        JSON.stringify(batch.id) + ' and cannot be re-verified. Only include task_groups you actually re-verified in this run.'});
      return;
    }
    // User-required task enforcement: a PASS cannot be recorded for a group
    // with any unacked user-required task. Agents have a documented tendency
    // to present deferral-first recommendations for user gates; this check
    // makes that impossible regardless of what the verifier reports.
    if (val === 'PASS') {
      const required = Array.isArray(userRequired[key]) ? userRequired[key] : [];
      const unacked = required.filter(taskId => !userAcks[taskId]);
      if (unacked.length > 0) {
        out({ok: false, error: 'Task_group ' + JSON.stringify(key) +
          ' cannot PASS: the following user-required task(s) have no entry in batches[].user_acks: ' +
          JSON.stringify(unacked) +
          '. Only the user, running ack-user-gate.sh in their own terminal, can record these acks. Do NOT attempt to run ack-user-gate.sh yourself — it is blocked by a PreToolUse hook.'});
        return;
      }
    }
  }

  // Apply verdicts.
  let newPassed = 0;
  let newFailed = 0;
  for (const [key, val] of entries) {
    if (val === 'PASS') {
      batch.group_status[key] = 'passed';
      newPassed += 1;
    } else {
      batch.group_status[key] = 'failed';
      newFailed += 1;
    }
  }
  batch.verifications_passed = (batch.verifications_passed || 0) + newPassed;
  batch.verifications_failed = (batch.verifications_failed || 0) + newFailed;
  s.last_updated = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));

  const groups = batch.task_groups || [];
  const groupsPassed = groups.filter(g => batch.group_status[g] === 'passed').length;
  out({
    ok: true,
    batch: batch.id,
    new_passed: newPassed,
    new_failed: newFailed,
    groups_passed: groupsPassed,
    groups_total: groups.length,
    batch_complete: groupsPassed === groups.length
  });
})()" "$STATE_FILE" "$VERDICT_ARG" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  new_passed=$(node -e "console.log(JSON.parse(process.argv[1]).new_passed)" "$result" 2>/dev/null)
  new_failed=$(node -e "console.log(JSON.parse(process.argv[1]).new_failed)" "$result" 2>/dev/null)
  groups_passed=$(node -e "console.log(JSON.parse(process.argv[1]).groups_passed)" "$result" 2>/dev/null)
  groups_total=$(node -e "console.log(JSON.parse(process.argv[1]).groups_total)" "$result" 2>/dev/null)
  batch_complete=$(node -e "console.log(JSON.parse(process.argv[1]).batch_complete)" "$result" 2>/dev/null)
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)

  if [ "$batch_complete" = "true" ]; then
    echo "mark-verified: Batch '$batch_id' fully verified ($groups_passed/$groups_total task_groups passed)."
  elif [ "$new_failed" != "0" ]; then
    echo "mark-verified: Recorded — $new_passed passed, $new_failed failed ($groups_passed/$groups_total task_groups now passing)."
  else
    echo "mark-verified: Recorded — $new_passed passed ($groups_passed/$groups_total task_groups now passing)."
  fi
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "mark-verified: ERROR — $err" >&2
exit 1
