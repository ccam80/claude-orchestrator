#!/usr/bin/env bash

# reopen-implementer-slot.sh — invoked by the implement-hybrid coordinator
# when an implementer returned "complete" (incrementing the `completed`
# counter via complete-implementer.sh) but the coordinator has concluded the
# work wasn't actually done, and wants to re-spawn an implementer for the
# same task_group WITHOUT first spending a verifier cycle just to hear it
# say "FAIL". This is a low-advertised escape hatch; the preferred recovery
# path remains letting the verifier catch the bogus completion.
#
# Semantics: undo the phantom completion — decrement BOTH `completed` and
# `spawned` on the current active batch by 1:
#   - decrementing `completed` closes the verifier gate (nothing to review)
#   - decrementing `spawned` opens the implementer cap (one slot free again)
# Net effect: the bogus implementer run is erased from the counters, and the
# coordinator can spawn a fresh implementer for the affected task_group.
#
# Preconditions (enforced):
#   - an active batch exists
#   - completed > verifications_passed + verifications_failed, i.e. there
#     is a completion that has NOT yet been verified (if the verifier has
#     already reviewed the bogus completion, the correct path is a normal
#     fix-implementer spawn against the now-open `failed` retry slot)
#   - spawned > 0 (there is a phantom completion to erase)
#
# Usage:
#   bash reopen-implementer-slot.sh <task_group_id> "<reason>"
#
# Both arguments are mandatory. They are written into recovery_log so the
# audit trail shows which group was reopened and why.

GROUP_ID="$1"
REASON="$2"

if [ -z "$GROUP_ID" ] || [ -z "$REASON" ]; then
  echo "reopen-implementer-slot: ERROR — task_group id and reason are both required." >&2
  echo "Usage: bash reopen-implementer-slot.sh <task_group_id> \"<reason>\"" >&2
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
  echo "reopen-implementer-slot: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  exit 1
fi

# --- Erase phantom completion ---
result=$(node -e "(() => {
  const fs = require('fs');
  const stateFile = process.argv[1];
  const groupId = process.argv[2];
  const reason = process.argv[3];
  const out = (obj) => console.log(JSON.stringify(obj));

  const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const batches = s.batches || [];
  const isBatchDone = (b) => {
    const gs = b.group_status || {};
    const groups = b.task_groups || [];
    return groups.length > 0 && groups.every(g => gs[g] === 'passed');
  };
  const batch = batches.find(b => !isBatchDone(b));
  if (!batch) {
    out({ok: false, error: 'No active batch — there is no implementer slot to reopen.'});
    return;
  }

  const groups = batch.task_groups || [];
  if (!groups.includes(groupId)) {
    out({ok: false, error: 'Task_group ' + JSON.stringify(groupId) +
      ' is not in the active batch ' + JSON.stringify(batch.id) +
      '. Known groups: ' + JSON.stringify(groups)});
    return;
  }

  const gs = batch.group_status || {};
  if (gs[groupId] === 'passed') {
    out({ok: false, error: 'Task_group ' + JSON.stringify(groupId) +
      ' is already passed. Reopening a passed group is not supported — that would overturn a verified PASS verdict.'});
    return;
  }

  const completed = batch.completed || 0;
  const passed = batch.verifications_passed || 0;
  const failed = batch.verifications_failed || 0;
  if (completed <= passed + failed) {
    out({ok: false, error: 'Batch ' + JSON.stringify(batch.id) +
      ' has no unreviewed completion to erase (completed=' + completed +
      ', reviewed=' + (passed + failed) +
      '). If the bogus completion has already been verified, use the normal fix-implementer path.'});
    return;
  }

  const spawned = batch.spawned || 0;
  if (spawned <= 0) {
    out({ok: false, error: 'Batch ' + JSON.stringify(batch.id) +
      ' has spawned=0; there is no implementer run to erase.'});
    return;
  }

  batch.spawned = spawned - 1;
  batch.completed = completed - 1;

  batch.recovery_log = batch.recovery_log || [];
  batch.recovery_log.push({
    script: 'reopen-implementer-slot.sh',
    timestamp: new Date().toISOString(),
    task_group: groupId,
    reason
  });

  s.last_updated = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));
  out({
    ok: true,
    batch: batch.id,
    task_group: groupId,
    spawned: batch.spawned,
    completed: batch.completed
  });
})()" "$STATE_FILE" "$GROUP_ID" "$REASON" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)
  group_id=$(node -e "console.log(JSON.parse(process.argv[1]).task_group)" "$result" 2>/dev/null)
  spawned=$(node -e "console.log(JSON.parse(process.argv[1]).spawned)" "$result" 2>/dev/null)
  completed=$(node -e "console.log(JSON.parse(process.argv[1]).completed)" "$result" 2>/dev/null)
  echo "reopen-implementer-slot: Erased phantom completion on batch '$batch_id' for group '$group_id' (spawned=$spawned, completed=$completed). Spawn a fresh implementer for this group — the gate is now open."
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "reopen-implementer-slot: ERROR — $err" >&2
exit 1
