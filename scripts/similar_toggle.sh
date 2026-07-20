#!/usr/bin/env bash
# similar_toggle.sh — toggle similar mode. With $CP_RUN_DIR/similar present,
# remove it (exit similar mode). Otherwise write the focused id (enter mode).
# Usage: similar_toggle.sh <focused_id>

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

# Similar mode is a prompt-mode concept; ignore the toggle in session mode.
[ -f "${CP_RUN_DIR}/sessions" ] && exit 0

ID="${1:-}"
similar_file="${CP_RUN_DIR}/similar"

if [ -f "$similar_file" ]; then
  rm -f "$similar_file"
  exit 0
fi

if [ -z "$ID" ]; then
  exit 0
fi

printf '%s' "$ID" > "$similar_file"
