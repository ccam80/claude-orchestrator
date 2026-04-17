#!/usr/bin/env bash

# i-fixed-it.sh — invoked by the implement-hybrid coordinator when it has
# made a trivial in-place fix (typo, lint nit, import reorder, etc.) to the
# code produced by a prior implementer and wants the wave-verifier to re-audit
# the batch WITHOUT spawning another implementer.
#
# This is an escape hatch. It is deliberately low-advertised: the intended
# recovery path for a failed verification is still to spawn a fix-implementer
# so the work is done under normal review. Use this script only when the fix
# is obvious, local, and not worth the cost of a full implementer spawn.
#
# Semantics: this is a "phantom implementer" record. It increments BOTH
# `spawned` and `completed` on the current active batch by 1:
#   - incrementing `completed` unlocks the verifier gate
#     (completed > verifications_passed + verifications_failed)
#   - incrementing `spawned` consumes a retry slot, so the spawn cap stays
#     tight — you do not get to i-fixed-it your way through a batch without
#     paying the same slot cost a real implementer would
#
# Preconditions (enforced):
#   - an active (not fully passed) batch exists
#   - at least one task_group in the active batch has group_status
#     "failed" — i.e. there is something to re-verify. If every group is
#     "pending" and nothing has been verified yet, the correct path is to
#     spawn an implementer, not to call this script.
#   - the current spawn slot cap allows one more spawn (spawned < cap);
#     otherwise the coordinator is trying to use this script to bypass the
#     cap, which is the exact failure mode the cap exists to prevent.
#
# Usage:
#   bash i-fixed-it.sh "<one-line description of what you fixed>"
#
# The description is mandatory and written into recovery_log in the state
# file so post-hoc audits can see why the coordinator intervened.

DESCRIPTION="$1"

if [ -z "$DESCRIPTION" ]; then
  echo "i-fixed-it: ERROR — one-line description of the fix is required." >&2
  echo "Usage: bash i-fixed-it.sh \"<what you fixed>\"" >&2
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
  echo "i-fixed-it: ERROR — could not locate spec/.hybrid-state.json above $PWD" >&2
  exit 1
fi

# --- Apply phantom-implementer record ---
result=$(node -e "(() => {
  const fs = require('fs');
  const stateFile = process.argv[1];
  const description = process.argv[2];
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
    out({ok: false, error: 'No active batch — every batch is already fully verified. i-fixed-it has no effect here.'});
    return;
  }

  const groups = batch.task_groups || [];
  const gs = batch.group_status || {};
  const hasFailed = groups.some(g => gs[g] === 'failed');
  if (!hasFailed) {
    out({ok: false, error: 'Active batch ' + JSON.stringify(batch.id) +
      ' has no failed task_group. i-fixed-it is only for recovering from a FAIL verdict; if no group has failed, spawn an implementer normally.'});
    return;
  }

  const tg = groups.length;
  const spawned = batch.spawned || 0;
  const failed = batch.verifications_failed || 0;
  const clarif = batch.stops_for_clarification || 0;
  const dead = batch.dead_implementers || 0;
  const cap = tg + failed + clarif + dead;
  if (spawned >= cap) {
    out({ok: false, error: 'Active batch ' + JSON.stringify(batch.id) +
      ' has no open spawn slot (spawned=' + spawned + ', cap=' + cap +
      '). i-fixed-it consumes a retry slot like a real implementer; if none is available, a failed verification must open one first.'});
    return;
  }

  batch.spawned = spawned + 1;
  batch.completed = (batch.completed || 0) + 1;

  batch.recovery_log = batch.recovery_log || [];
  batch.recovery_log.push({
    script: 'i-fixed-it.sh',
    timestamp: new Date().toISOString(),
    description
  });

  s.last_updated = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));
  out({
    ok: true,
    batch: batch.id,
    spawned: batch.spawned,
    completed: batch.completed,
    verifications_passed: batch.verifications_passed || 0,
    verifications_failed: batch.verifications_failed || 0
  });
})()" "$STATE_FILE" "$DESCRIPTION" 2>/dev/null || echo '{"ok":false,"error":"node execution failed"}')

ok=$(node -e "try { console.log(JSON.parse(process.argv[1]).ok) } catch (e) { console.log('false') }" "$result" 2>/dev/null || echo "false")

if [ "$ok" = "true" ]; then
  batch_id=$(node -e "console.log(JSON.parse(process.argv[1]).batch)" "$result" 2>/dev/null)
  spawned=$(node -e "console.log(JSON.parse(process.argv[1]).spawned)" "$result" 2>/dev/null)
  completed=$(node -e "console.log(JSON.parse(process.argv[1]).completed)" "$result" 2>/dev/null)
  echo "i-fixed-it: Phantom-implementer record applied on batch '$batch_id' (spawned=$spawned, completed=$completed). Spawn a wave-verifier next to audit the fix — do not advance past verification."
  exit 0
fi

err=$(node -e "console.log(JSON.parse(process.argv[1]).error || 'unknown error')" "$result" 2>/dev/null || echo "unknown error")
echo "i-fixed-it: ERROR — $err" >&2
exit 1
