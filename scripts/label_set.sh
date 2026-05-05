#!/usr/bin/env bash
# label_set.sh — set or clear a prompt's optional short label.
# Usage:
#   label_set.sh <prompt_id>              interactive (read -e prefilled with current)
#   label_set.sh <prompt_id> <label>      non-interactive (also used by tests)
#
# Empty/whitespace-only input clears the label. Setting a non-empty label
# also auto-stars the prompt so the user can find it again.
# Labels are clamped to 60 characters and stripped of CR/LF.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3
ensure_db

PID="${1:-}"
if [ -z "$PID" ] || ! printf '%s' "$PID" | grep -qE '^[0-9]+$'; then
  printf 'label_set.sh: invalid id: %s\n' "$PID" >&2
  exit 1
fi

sq_pid="$(sql_quote "$PID")"

# Existence check — silent no-op for missing rows mirrors pin.sh behavior.
exists="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT count(*) FROM prompts WHERE id=${sq_pid};" 2>/dev/null || printf '0')"
if [ "${exists:-0}" -eq 0 ]; then
  exit 0
fi

if [ $# -ge 2 ]; then
  lbl="$2"
else
  existing="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT COALESCE(label, '') FROM prompts WHERE id=${sq_pid};" 2>/dev/null || true)"
  # readline-edited prompt; -e + -i prefills with the current label
  read -r -e -i "$existing" -p "Label: " lbl || lbl=""
fi

# Strip CR/LF; clamp to 60 chars.
lbl="${lbl//$'\n'/}"
lbl="${lbl//$'\r'/}"
# Trim leading/trailing whitespace.
lbl="${lbl#"${lbl%%[![:space:]]*}"}"
lbl="${lbl%"${lbl##*[![:space:]]}"}"
if [ "${#lbl}" -gt 60 ]; then
  lbl="${lbl:0:60}"
fi

if [ -z "$lbl" ]; then
  sqlite3 -bail "$CP_DB" >/dev/null \
    "UPDATE prompts SET label=NULL WHERE id=${sq_pid};"
else
  sq_lbl="$(sql_quote "$lbl")"
  NOW="$(now_ms)"
  sqlite3 -bail "$CP_DB" >/dev/null <<SQL
BEGIN;
UPDATE prompts SET label=${sq_lbl} WHERE id=${sq_pid};
UPDATE prompts SET pinned=1, pinned_at=${NOW} WHERE id=${sq_pid} AND pinned=0;
COMMIT;
SQL
fi
