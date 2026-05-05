#!/usr/bin/env bash
# cheatsheet_toggle.sh — toggle the cheatsheet overlay.
# Mirrors similar_toggle.sh: with $CP_RUN_DIR/cheatsheet present, remove it
# (back to row preview); otherwise create it (show keymap in preview pane).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

state="${CP_RUN_DIR}/cheatsheet"

if [ -f "$state" ]; then
  rm -f "$state"
else
  : > "$state"
fi
