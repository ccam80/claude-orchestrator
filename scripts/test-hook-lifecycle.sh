#!/usr/bin/env bash
# test-hook-lifecycle.sh — End-to-end test of all four hook scripts
# Walks through: spawn -> complete -> verify(fail) -> retry -> verify(pass) -> batch-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="spec/.hybrid-state.json"
PASS=0
FAIL=0

# Helper: run a hook script, capture exit code, stdout, stderr
run_hook() {
  local script="$1"
  local stdin_json="$2"
  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)

  local exit_code=0
  echo "$stdin_json" | bash "$SCRIPT_DIR/$script" > "$stdout_file" 2> "$stderr_file" || exit_code=$?

  LAST_EXIT=$exit_code
  LAST_STDOUT=$(cat "$stdout_file")
  LAST_STDERR=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
}

# Helper: assert exit code
assert_exit() {
  local expected="$1"
  local label="$2"
  if [ "$LAST_EXIT" -eq "$expected" ]; then
    echo "  PASS: $label (exit=$LAST_EXIT)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit=$expected, got exit=$LAST_EXIT)"
    [ -n "$LAST_STDOUT" ] && echo "    stdout: $LAST_STDOUT"
    [ -n "$LAST_STDERR" ] && echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: read a counter from state
read_counter() {
  local batch_idx="$1"
  local field="$2"
  node -e "const s=JSON.parse(require('fs').readFileSync('$STATE_FILE','utf8'));console.log(s.batches[$batch_idx].$field||0)"
}

# Helper: assert counter value
assert_counter() {
  local batch_idx="$1"
  local field="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual=$(read_counter "$batch_idx" "$field")
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label ($field=$actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected $field=$expected, got $field=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

IMPL_JSON='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:implementer","prompt":"test"}}'
VERIFIER_JSON='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:wave-verifier","prompt":"test"}}'
OTHER_JSON='{"tool_name":"Agent","tool_input":{"subagent_type":"some-other-agent","prompt":"test"}}'

# Simulate PostToolUse (tool_response included)
IMPL_POST='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:implementer","prompt":"test"},"tool_response":"done"}'
VERIFY_PASS_POST='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:wave-verifier","prompt":"test"},"tool_response":"## Verdict: PASS PASS"}'
VERIFY_FAIL_POST='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:wave-verifier","prompt":"test"},"tool_response":"## Verdict: PASS FAIL"}'
VERIFY_PASS_SINGLE='{"tool_name":"Agent","tool_input":{"subagent_type":"claude-orchestrator:wave-verifier","prompt":"test"},"tool_response":"## Verdict: PASS"}'

echo "=== BATCH 1: Two task groups (1.1, 1.2) ==="
echo ""

echo "--- 1. Non-implementer agent passes through ---"
run_hook gate-implementer.sh "$OTHER_JSON"
assert_exit 0 "Non-implementer passes gate-implementer"
assert_counter 0 spawned 0 "spawned unchanged"

echo ""
echo "--- 2. Spawn implementer #1 (should allow) ---"
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 0 "First implementer allowed"
assert_counter 0 spawned 1 "spawned incremented to 1"

echo ""
echo "--- 3. Spawn implementer #2 (should allow) ---"
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 0 "Second implementer allowed"
assert_counter 0 spawned 2 "spawned incremented to 2"

echo ""
echo "--- 4. Spawn implementer #3 (should BLOCK - cap reached) ---"
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 2 "Third implementer blocked (spawn cap)"

echo ""
echo "--- 5. Verifier before any completions (should BLOCK) ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 2 "Verifier blocked (nothing to verify)"

echo ""
echo "--- 6. Complete implementer #1 ---"
run_hook complete-implementer.sh "$IMPL_POST"
assert_exit 0 "Complete hook runs"
assert_counter 0 completed 1 "completed incremented to 1"

echo ""
echo "--- 7. Spawn implementer while unreviewed work exists (should BLOCK) ---"
# spawned(2) >= tg(2)+failed(0) => spawn_cap blocks first
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 2 "Implementer blocked (spawn cap, no retry slots)"

echo ""
echo "--- 8. Verifier with 1 completed, 0 reviewed (should ALLOW) ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 0 "Verifier allowed (unreviewed work exists)"

echo ""
echo "--- 9. Complete implementer #2 ---"
run_hook complete-implementer.sh "$IMPL_POST"
assert_exit 0 "Complete hook runs"
assert_counter 0 completed 2 "completed incremented to 2"

echo ""
echo "=== VERIFICATION FAIL SCENARIO ==="
echo ""

echo "--- 10. Mark verified: PASS FAIL ---"
run_hook mark-verified.sh "$VERIFY_FAIL_POST"
assert_exit 0 "Mark-verified hook runs"
assert_counter 0 verifications_passed 1 "passed incremented to 1"
assert_counter 0 verifications_failed 1 "failed incremented to 1"

echo ""
echo "--- 11. Spawn retry implementer (fail added retry slot) ---"
# spawned(2) < tg(2) + failed(1) = 3, so one retry slot available
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 0 "Retry implementer allowed (failed added slot)"
assert_counter 0 spawned 3 "spawned incremented to 3"

echo ""
echo "--- 12. Complete retry implementer ---"
run_hook complete-implementer.sh "$IMPL_POST"
assert_exit 0 "Complete hook runs"
assert_counter 0 completed 3 "completed incremented to 3"

echo ""
echo "--- 13. Verifier for retry (should ALLOW - 1 unreviewed) ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 0 "Verifier allowed for retry"

echo ""
echo "=== VERIFICATION PASS SCENARIO ==="
echo ""

echo "--- 14. Mark verified: PASS (retry passed) ---"
run_hook mark-verified.sh "$VERIFY_PASS_SINGLE"
assert_exit 0 "Mark-verified hook runs"
assert_counter 0 verifications_passed 2 "passed now 2 (batch complete)"
assert_counter 0 verifications_failed 1 "failed still 1"

echo ""
echo "--- 15. Verifier on completed batch (should BLOCK) ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 2 "Verifier blocked (batch fully verified)"

echo ""
echo "=== BATCH 2: One task group (2.1) ==="
echo ""

echo "--- 16. Spawn implementer for batch 2 (should allow) ---"
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 0 "Batch 2 implementer allowed"
assert_counter 1 spawned 1 "batch-2 spawned=1"

echo ""
echo "--- 17. Complete batch 2 implementer ---"
run_hook complete-implementer.sh "$IMPL_POST"
assert_exit 0 "Complete hook runs"
assert_counter 1 completed 1 "batch-2 completed=1"

echo ""
echo "--- 18. Verifier for batch 2 (should allow) ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 0 "Batch 2 verifier allowed"

echo ""
echo "--- 19. Mark batch 2 verified: PASS ---"
run_hook mark-verified.sh "$VERIFY_PASS_SINGLE"
assert_exit 0 "Mark-verified hook runs"
assert_counter 1 verifications_passed 1 "batch-2 fully verified"

echo ""
echo "--- 20. All batches done — verifier should BLOCK ---"
run_hook gate-verifier.sh "$VERIFIER_JSON"
assert_exit 2 "Verifier blocked (all batches verified)"

echo ""
echo "--- 21. All batches done — implementer should allow (no active batch) ---"
run_hook gate-implementer.sh "$IMPL_JSON"
assert_exit 0 "Implementer passes (no active batch = allow)"

echo ""
echo "========================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
