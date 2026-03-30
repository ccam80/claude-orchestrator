#!/usr/bin/env bash

# verify-wave-gate.sh — PreToolUse hook for Agent tool
# Blocks implementer spawns when the previous wave has not been verified.
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow the tool call
#   exit 2 — block the tool call (stdout shown to agent as reason)
#
# State machine (spec/.hybrid-state.json → status field):
#   implementing → wave_complete → verifying → verified ──→ (next wave)
#                                           → failed → fixing → verifying …

# --- Read hook input from stdin into a temp file (avoids heredoc issues on Windows) ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

# --- Only gate calls whose description looks like an implementer spawn ---
is_implementer=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const d = (j.tool_input && (j.tool_input.description || '')) || '';
  const lc = d.toLowerCase();
  if (lc.includes('review') || lc.includes('baseline') || lc.includes('fix-verify')) {
    console.log('no');
  } else if (lc.includes('implement')) {
    console.log('yes');
  } else {
    console.log('no');
  }
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_implementer" != "yes" ]; then
  exit 0
fi

# --- Locate the state file ---
# Walk up from cwd to find spec/.hybrid-state.json (supports being invoked from subdirs)
STATE_FILE=""
dir="$PWD"
while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -f "$dir/spec/.hybrid-state.json" ]; then
    STATE_FILE="$dir/spec/.hybrid-state.json"
    break
  fi
  dir=$(dirname "$dir")
done

# No state file → first wave, nothing to gate
if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# --- Read state ---
state_json=$(node -e "
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  console.log(JSON.stringify({ status: s.status || 'unknown', verified: s.verified === true }));
" "$STATE_FILE" 2>/dev/null || echo '{"status":"unknown","verified":false}')

status=$(node -e "console.log(JSON.parse(process.argv[1]).status)" "$state_json" 2>/dev/null || echo "unknown")
verified=$(node -e "console.log(JSON.parse(process.argv[1]).verified)" "$state_json" 2>/dev/null || echo "false")

# --- Gate logic ---
# Allow if: no prior wave yet, currently implementing, or already verified
case "$status" in
  implementing|verified|unknown)
    exit 0
    ;;
  wave_complete|verifying|failed|fixing)
    if [ "$verified" = "true" ]; then
      exit 0
    fi
    echo "BLOCKED: Wave verification gate — previous wave status is '$status' and verified=$verified."
    echo "The coordinator must complete wave verification (reviewer + tests) before spawning new implementers."
    echo "State file: $STATE_FILE"
    exit 2
    ;;
  *)
    # Unknown status — allow but warn
    exit 0
    ;;
esac
