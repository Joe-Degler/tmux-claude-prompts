#!/usr/bin/env bash
# group_pick.sh — interactive picker for the active group.
# Bound to ctrl-g via fzf `execute` (terminal available). Writes the chosen
# group id to $CP_RUN_DIR/group; Esc / empty input cancels without writing.
# Typing a brand-new name creates the group (NOCASE-uniqued) and selects it.
#
# When already in group mode (the file $CP_RUN_DIR/group exists), the picker
# additionally shows a synthetic top row with id=0 — selecting it clears
# group mode and exits, with no INSERT into groups.
#
# Non-interactive flag:
#   --exit   Equivalent to selecting the exit-sentinel: clear group mode and exit 0.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

group_file="${CP_RUN_DIR}/group"

# --- Non-interactive: --exit unconditionally clears group mode. ---
if [ "${1:-}" = "--exit" ]; then
  rm -f "$group_file"
  exit 0
fi

require_dep sqlite3
require_dep fzf
ensure_db

# Build the picker rows: <id>\t<name> (<count>)
rows="$(sqlite3 -bail -separator $'\t' -cmd ".timeout 3000" "$CP_DB" \
  "SELECT g.id, g.name || ' (' || (SELECT count(*) FROM group_members WHERE group_id=g.id) || ')' FROM groups g ORDER BY g.ts DESC;" \
  2>/dev/null || true)"

# When already in group mode, prepend the exit-sentinel.
if [ -f "$group_file" ]; then
  sentinel=$'0\t(no group — exit group mode)'
  if [ -n "$rows" ]; then
    rows="${sentinel}"$'\n'"${rows}"
  else
    rows="${sentinel}"
  fi
fi

# Run nested fzf — --print-query so we can detect "typed a brand-new name".
# Exit codes: 0 = match, 1 = no match (still emits typed query), 130 = aborted.
set +e
picked="$(printf '%s\n' "$rows" | fzf \
  --prompt='Group> ' \
  --print-query \
  --header='Select existing group or type a new name; Enter to confirm, Esc to cancel' \
  --no-sort \
  --height=40% \
  --delimiter=$'\t' \
  --with-nth=2.. \
  --layout=reverse)"
status=$?
set -e

# Esc → 130. Anything other than 0 or 1 = bail.
if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
  exit 0
fi

# --print-query → first line is the typed query, then 0+ matched lines.
typed="$(printf '%s\n' "$picked" | sed -n '1p')"
match="$(printf '%s\n' "$picked" | sed -n '2p')"

GID=""

if [ -n "$match" ]; then
  # First tab-separated field is the id.
  GID="${match%%$'\t'*}"
elif [ -n "$typed" ]; then
  # No selection but the user typed something → create-or-fetch by name.
  # Strip leading/trailing whitespace.
  name="$typed"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  if [ -z "$name" ]; then
    exit 0
  fi
  sq_name="$(sql_quote "$name")"
  NOW="$(now_ms)"
  sqlite3 -bail "$CP_DB" >/dev/null <<SQL
INSERT OR IGNORE INTO groups(name, ts) VALUES (${sq_name}, ${NOW});
SQL
  GID="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT id FROM groups WHERE name=${sq_name} COLLATE NOCASE;" \
    2>/dev/null || true)"
fi

if [ -z "$GID" ] || ! printf '%s' "$GID" | grep -qE '^[0-9]+$'; then
  exit 0
fi

# Sentinel: id 0 means "exit group mode" — never INSERT, never write.
if [ "$GID" = "0" ]; then
  rm -f "$group_file"
  exit 0
fi

# Touch ts so most-recently-used groups float to the top of the picker.
sq_gid="$(sql_quote "$GID")"
NOW="$(now_ms)"
sqlite3 -bail "$CP_DB" >/dev/null \
  "UPDATE groups SET ts=${NOW} WHERE id=${sq_gid};"

printf '%s' "$GID" > "$group_file"
