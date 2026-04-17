#!/usr/bin/env bash

# gate-user-ack.sh — PreToolUse hook that blocks all Claude-initiated bash
# invocations of scripts/ack-user-gate.sh.
#
# Purpose: ack-user-gate.sh records the user's personal confirmation that a
# hard-stop user-required task has been completed. Agents (implementers,
# verifiers, reviewers, and the coordinator) must NEVER run this script on
# the user's behalf — doing so would forge the user's signature and defeat
# the whole user-gate mechanism. Agents have shown a tendency to present
# "deferral-first" recommendations for user-required tasks; this hook makes
# that pattern impossible by blocking every agent-initiated call.
#
# How the gate works in practice: the user runs ack-user-gate.sh from their
# own terminal (a regular shell session, NOT a `!`-prefixed call inside
# Claude Code — `!` goes through the Bash tool and is therefore subject to
# this hook). The state file is updated by the user's ack, and Claude can
# then read that updated state via the normal Read tool.
#
# Hook contract:
#   stdin  — JSON with { tool_name, tool_input }
#   exit 0 — allow (command does not mention ack-user-gate.sh)
#   exit 2 — block, with reason on stderr

# --- Read stdin ---
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

# --- Extract command and check for ack-user-gate.sh invocation ---
is_ack=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const cmd = (j.tool_input && j.tool_input.command) || '';
  console.log(/(^|[\s/\\\\'\"])ack-user-gate\.sh(\s|\$|['\"])/.test(cmd) ? 'yes' : 'no');
" "$TMPINPUT" 2>/dev/null || echo "no")

if [ "$is_ack" != "yes" ]; then
  exit 0
fi

# --- Block with a message directing the agent to present the command to the user ---
CMD=$(node -e "
  const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  console.log((j.tool_input && j.tool_input.command) || '');
" "$TMPINPUT" 2>/dev/null)

cat <<MSG >&2
BLOCKED: ack-user-gate.sh is a USER-ONLY script. It cannot be run by any agent, including the coordinator.

User-required tasks are hard-stop gates. Only the user, running this script in their own terminal (outside Claude Code), can record the ack. Agent-initiated attempts — including running via the Bash tool, the \`!\` prefix, a background Task, or within a subagent session — are blocked.

Correct flow:
  1. Identify the user-required task_id and describe the real-world action the user must perform.
  2. Use AskUserQuestion to present the EXACT command to the user:
       bash "\${CLAUDE_PLUGIN_ROOT}/scripts/ack-user-gate.sh" <task_id> "<evidence>"
     Tell them to open a separate terminal (not this Claude Code session) and run it there.
  3. Wait for the user to confirm they ran it. Then read spec/.hybrid-state.json to see the new user_acks entry.
  4. Only after the ack is recorded can the verifier PASS the task_group. mark-verified.sh enforces this server-side.

Blocked command (truncated): ${CMD:0:200}
MSG
exit 2
