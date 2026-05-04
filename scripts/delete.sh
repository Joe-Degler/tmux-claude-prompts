#!/usr/bin/env bash
# delete.sh — remove a prompt row from the DB by id.
# Cascade removes paste_contents; trigger removes FTS row.
# Usage: delete.sh <id>
# Exit codes: 0 success/no-op, 1 invalid id.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

id="${1:-}"

# Validate: must be a non-empty integer
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'delete.sh: invalid id: %s\n' "$id" >&2
  exit 1
fi

ensure_db

sqlite3 -bail -cmd ".timeout 3000" -cmd "PRAGMA foreign_keys=ON;" "$CP_DB" <<SQL
DELETE FROM prompts WHERE id = ${id};
SQL
