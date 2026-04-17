#!/usr/bin/env bash

# ack-user-gate.sh — USER-ONLY script that records the user's personal
# confirmation that a user-required task has been completed.
#
# =============================================================================
# THIS SCRIPT MUST ONLY BE RUN BY THE USER, IN THEIR OWN TERMINAL.
# =============================================================================
# A PreToolUse hook (gate-user-ack.sh) blocks every Claude-initiated bash call
# that tries to run this script. Agents (implementers, verifiers, reviewers,
# coordinators) are prohibited from running it — doing so would forge the
# user's confirmation of a hard-stop task, defeating the whole user-gate
# mechanism. The coordinator's job is to present the exact ack command to
# the user via AskUserQuestion and wait until the user confirms they have
# run it in their own terminal.
#
# How it works:
#   1. The phase spec lists certain tasks as requiring user action.
#   2. The coordinator records those task_ids in
#      spec/.hybrid-state.json under batches[].user_required_tasks
#      keyed by task_group.
#   3. When the user completes the real-world action (configures secrets,
#      provisions a cloud resource, updates DNS, verifies a UI by hand, etc.)
#      they personally run THIS script, which writes an entry into
#      batches[].user_acks[task_id].
#   4. mark-verified.sh refuses to record PASS for a task_group whose
#      user_required_tasks list contains any unacked task — so the gate is
#      enforced server-side regardless of what the verifier reports.
#
# Usage (run this in your OWN terminal, not inside a Claude Code session):
#   bash ack-user-gate.sh <task_id> "<evidence of what you did>"
#
# Example:
#   bash ack-user-gate.sh T2.4 "Configured STRIPE_API_KEY in Vault at secrets/prod/stripe"
#
# The evidence string is mandatory. It is stored in the state file and read
# by the verifier and by any human auditing the batch later.

TASK_ID="$1"
EVIDENCE="$2"

if [ -z "$TASK_ID" ] || [ -z "$EVIDENCE" ]; then
  echo "ack-user-gate: ERROR — task_id and evidence are both required." >&2
  echo "Usage: bash ack-user-gate.sh <task_id> \"<evidence of what you did>\"" >&2
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
  echo "ack-user-gate: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  echo "Run this script from inside the project directory (anywhere at or below the project root)." >&2
  exit 1
fi

# --- Record the ack on the first batch whose user_required_tasks lists the task_id ---
result=$(node -e "(() => {
  const fs = require('fs');
  const stateFile = process.argv[1];
  const taskId = process.argv[2];
  const evidence = process.argv[3];
  const out = (obj) => console.log(JSON.stringify(obj));

  const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const batches = s.batches || [];

  let foundBatch = null;
  let foundGroup = null;
  for (const b of batches) {
    const urt = b.user_required_tasks || {};
    for (const [group, ids] of Object.entries(urt)) {
      if (Array.isArray(ids) && ids.includes(taskId)) {
        foundBatch = b;
        foundGroup = group;
        break;
      }
    }
    if (foundBatch) break;
  }

  if (!foundBatch) {
    out({ok: false, error: 'Task ' + JSON.stringify(taskId) +
      ' is not listed as user-required in any batch. The coordinator must add it to batches[].user_required_tasks[<group>] before the ack is accepted.'});
    return;
  }

  foundBatch.user_acks = foundBatch.user_acks || {};
  const existing = foundBatch.user_acks[taskId];
  foundBatch.user_acks[taskId] = {
    task_group: foundGroup,
    timestamp: new Date().toISOString(),
    evidence,
    superseded: existing ? [existing, ...(existing.superseded || [])] : undefined
  };
  if (!existing) delete foundBatch.user_acks[taskId].superseded;

  s.last_updated = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));
  out({
    ok: true,
    batch: foundBatch.id,
    task_group: foundGroup,
    task: taskId,
    was_already_acked: !!existing
  });
})()" "$STATE_FILE" "$TASK_ID" "$EVIDENCE" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)
  group_id=$(node -e "console.log(JSON.parse(process.argv[1]).task_group)" "$result" 2>/dev/null)
  already=$(node -e "console.log(JSON.parse(process.argv[1]).was_already_acked)" "$result" 2>/dev/null)
  if [ "$already" = "true" ]; then
    echo "ack-user-gate: Updated ack for task '$TASK_ID' (batch '$batch_id', group '$group_id'). Previous ack preserved under 'superseded'."
  else
    echo "ack-user-gate: Recorded ack for task '$TASK_ID' (batch '$batch_id', group '$group_id'). The verifier can now PASS this task_group once all other checks succeed."
  fi
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "ack-user-gate: ERROR — $err" >&2
exit 1
