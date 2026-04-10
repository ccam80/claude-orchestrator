#!/usr/bin/env bash
set -euo pipefail

# Copies agent/reference files to spec/.context/ so spawned agents can read them.
# Usage: materialize-context.sh <mode> <plugin_root> <project_root>
#   mode: "hybrid" (rules + lock-protocol), "review" (rules + reviewer), or "review-spec" (rules + review-spec)

mode="${1:?Usage: materialize-context.sh <hybrid|review|review-spec> <plugin_root> <project_root>}"
plugin_root="${2:?Missing plugin_root}"
project_root="${3:?Missing project_root}"

dest="${project_root}/spec/.context"
mkdir -p "$dest"

cp "${plugin_root}/references/rules.md" "$dest/rules.md"

if [ "$mode" = "hybrid" ]; then
  cp "${plugin_root}/references/lock-protocol.md" "$dest/lock-protocol.md"
elif [ "$mode" = "review" ]; then
  cp "${plugin_root}/agents/reviewer.md" "$dest/reviewer.md"
elif [ "$mode" = "review-spec" ]; then
  cp "${plugin_root}/agents/review-spec.md" "$dest/review-spec.md"
else
  exit 1
fi
