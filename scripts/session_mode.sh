#!/usr/bin/env bash
# session_mode.sh — toggle session-search mode ($CP_RUN_DIR/sessions).
# Entering session mode clears group/similar state: those are prompt-mode
# filters and would otherwise silently reactivate on exit.
# A project scope that has zero rows in the destination mode falls back to
# everywhere, so a mode switch never lands on a stuck-empty list.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

sessions_file="${CP_RUN_DIR}/sessions"

if [ -f "$sessions_file" ]; then
  rm -f "$sessions_file"
  dest_count_sql="SELECT count(*) FROM prompts WHERE project ="
else
  rm -f "${CP_RUN_DIR}/group" "${CP_RUN_DIR}/similar"
  : > "$sessions_file"
  dest_count_sql="SELECT count(*) FROM sessions WHERE project ="
fi

scope=""
[ -f "$CP_SCOPE_FILE" ] && scope="$(cat "$CP_SCOPE_FILE")"
if [ -n "$scope" ] && [ "$scope" != "everywhere" ]; then
  n="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "${dest_count_sql} $(sql_quote "$scope");" 2>/dev/null || printf '0')"
  if [ "${n:-0}" -eq 0 ]; then
    "${SCRIPT_DIR}/scope.sh" set everywhere
  fi
fi
