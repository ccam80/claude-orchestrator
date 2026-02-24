#!/usr/bin/env bash
set -euo pipefail

# Copies agent/reference files to spec/.context/ so spawned agents can read them.
# Usage: materialize-context.sh <mode> <plugin_root> <project_root>
#   mode: "implement" (5 files), "hybrid" (3 files), or "review" (2 files)

mode="${1:?Usage: materialize-context.sh <implement|review> <plugin_root> <project_root>}"
plugin_root="${2:?Missing plugin_root}"
project_root="${3:?Missing project_root}"

dest="${project_root}/spec/.context"
mkdir -p "$dest"

cp "${plugin_root}/references/rules.md" "$dest/rules.md"

if [ "$mode" = "implement" ]; then
  cp "${plugin_root}/references/lock-protocol.md" "$dest/lock-protocol.md"
  cp "${plugin_root}/agents/orchestrator.md"      "$dest/orchestrator.md"
  cp "${plugin_root}/agents/implementer.md"       "$dest/implementer.md"
  cp "${plugin_root}/agents/reviewer.md"          "$dest/reviewer.md"
elif [ "$mode" = "hybrid" ]; then
  cp "${plugin_root}/references/lock-protocol.md" "$dest/lock-protocol.md"
  cp "${plugin_root}/agents/reviewer.md"          "$dest/reviewer.md"
  # No orchestrator.md (eliminated) or implementer.md (loaded via agent type)
elif [ "$mode" = "review" ]; then
  cp "${plugin_root}/agents/reviewer.md" "$dest/reviewer.md"
else
  exit 1
fi
