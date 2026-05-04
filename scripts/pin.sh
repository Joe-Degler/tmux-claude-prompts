#!/usr/bin/env bash
# pin.sh — toggle pinned bit for a prompt row.
# Usage: pin.sh <id>
# Exit codes: 0 success/no-op, 1 invalid id.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

id="${1:-}"

# Validate: must be a non-empty integer
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'pin.sh: invalid id: %s\n' "$id" >&2
  exit 1
fi

ensure_db

# Toggle pinned 0↔1 and update pinned_at accordingly.
# Non-existent id is a no-op (UPDATE affects 0 rows → exit 0).
NOW_MS="$(now_ms)"

sqlite3 -bail -cmd ".timeout 3000" "$CP_DB" <<SQL
UPDATE prompts
SET
  pinned    = CASE WHEN pinned = 0 THEN 1 ELSE 0 END,
  pinned_at = CASE WHEN pinned = 0 THEN ${NOW_MS} ELSE NULL END
WHERE id = ${id};
SQL
