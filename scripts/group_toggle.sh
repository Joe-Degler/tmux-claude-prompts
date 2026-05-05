#!/usr/bin/env bash
# group_toggle.sh — toggle group-filter mode. With $CP_RUN_DIR/group present,
# remove it (exit group mode). Otherwise write the supplied <group_id>.
# Usage: group_toggle.sh <group_id>
#
# Currently unused by the popup (group_pick.sh writes the file directly,
# popup.sh removes it on launch). Kept for symmetry with similar_toggle.sh
# and convenient scripted use.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

GID="${1:-}"
group_file="${CP_RUN_DIR}/group"

if [ -f "$group_file" ]; then
  rm -f "$group_file"
  exit 0
fi

if [ -z "$GID" ]; then
  exit 0
fi

printf '%s' "$GID" > "$group_file"
