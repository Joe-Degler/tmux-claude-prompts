#!/usr/bin/env bash
# group.sh — emit fzf-formatted rows for the members of a group.
# Usage: group.sh <group_id> [<refine_query>]
#
# Strategy: SELECT prompt ids from group_members in (pinned, recent) order,
# pipe them through render_ids.sh which handles refinement and rendering.
# Empty/nonexistent group → exit 0 with no output.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

GROUP_ID="${1:-}"
REFINE_Q="${2:-}"

if [ -z "$GROUP_ID" ] || ! printf '%s' "$GROUP_ID" | grep -qE '^[0-9]+$'; then
  exit 0
fi

sq_gid="$(sql_quote "$GROUP_ID")"
ids="$(sqlite3 -bail -cmd ".timeout 3000" "$CP_DB" \
  "SELECT gm.prompt_id FROM group_members gm JOIN prompts p ON p.id = gm.prompt_id WHERE gm.group_id = ${sq_gid} ORDER BY p.pinned DESC, p.ts DESC;" \
  2>/dev/null || true)"

if [ -z "$ids" ]; then
  exit 0
fi

printf '%s\n' "$ids" | "${SCRIPT_DIR}/render_ids.sh" "$REFINE_Q"
