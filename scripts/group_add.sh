#!/usr/bin/env bash
# group_add.sh — toggle membership of <prompt_id> in the active group.
# Usage: group_add.sh <prompt_id>
#
# Reads $CP_RUN_DIR/group; if absent, no-op (no active group). If the group
# id no longer exists, the stale file is removed and we exit silently.
# Toggling INTO the group also auto-stars the prompt (pinned=1).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3
ensure_db

PID="${1:-}"
if [ -z "$PID" ] || ! printf '%s' "$PID" | grep -qE '^[0-9]+$'; then
  exit 0
fi

group_file="${CP_RUN_DIR}/group"
[ -f "$group_file" ] || exit 0

GID="$(< "$group_file")"
if [ -z "$GID" ] || ! printf '%s' "$GID" | grep -qE '^[0-9]+$'; then
  exit 0
fi

sq_gid="$(sql_quote "$GID")"
sq_pid="$(sql_quote "$PID")"

# Verify group still exists; otherwise remove the stale state file and exit.
exists="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT count(*) FROM groups WHERE id=${sq_gid};" 2>/dev/null || printf '0')"
if [ "${exists:-0}" -eq 0 ]; then
  rm -f "$group_file"
  exit 0
fi

# Already a member? toggle off; otherwise insert + auto-star.
is_member="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT count(*) FROM group_members WHERE group_id=${sq_gid} AND prompt_id=${sq_pid};" \
  2>/dev/null || printf '0')"

NOW="$(now_ms)"

if [ "${is_member:-0}" -ge 1 ]; then
  sqlite3 -bail "$CP_DB" >/dev/null <<SQL
BEGIN;
DELETE FROM group_members WHERE group_id=${sq_gid} AND prompt_id=${sq_pid};
COMMIT;
SQL
else
  sqlite3 -bail "$CP_DB" >/dev/null <<SQL
BEGIN;
INSERT INTO group_members(group_id, prompt_id, ts) VALUES (${sq_gid}, ${sq_pid}, ${NOW});
UPDATE prompts SET pinned=1, pinned_at=${NOW} WHERE id=${sq_pid} AND pinned=0;
COMMIT;
SQL
fi
