#!/usr/bin/env bash

# clear-locks.sh — clear task and file locks under spec/.locks/.
#
# Usage:
#   bash clear-locks.sh           # between batches: wipe contents, leave empty
#                                 # tasks/ and files/ dirs ready for next batch
#   bash clear-locks.sh --purge   # end of run: remove the spec/.locks/ tree
#
# Idempotent: silently succeeds whether or not the locks tree exists.
# Locates the project root by walking up from $PWD looking for spec/, so the
# script works whether invoked from the project root or from a subdirectory.

set -u

# --- Locate project root (dir containing spec/) ---
ROOT=""
dir="$PWD"
while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -d "$dir/spec" ]; then
    ROOT="$dir"
    break
  fi
  dir=$(dirname "$dir")
done

if [ -z "$ROOT" ]; then
  exit 0
fi

LOCKS_DIR="$ROOT/spec/.locks"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$LOCKS_DIR"
  exit 0
fi

rm -rf "$LOCKS_DIR"
mkdir -p "$LOCKS_DIR/tasks" "$LOCKS_DIR/files"
exit 0
