#!/usr/bin/env bash
# render_ids.sh — read ids from stdin (one per line, in desired order) and
# emit fzf-formatted rows preserving that order.
# Usage: render_ids.sh [<refine_query>]
#
# Optional <refine_query> AND-filters the candidate set via FTS5 (the rank
# from the input order is preserved — FTS5 is just a filter, not a sort).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"
. "${SCRIPT_DIR}/render.sh"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

REFINE_Q="${1:-}"

ids="$(cat)"
if [ -z "$ids" ]; then
  exit 0
fi

RS=$'\x1e'
sql_tmp="$(mktemp /tmp/cp_render_ids_XXXXXX.sql)"
trap 'rm -f "$sql_tmp"' EXIT

{
  printf 'WITH ranked(id, rk) AS (VALUES\n'
  rk=0
  first=1
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if [ "$first" -eq 1 ]; then
      printf '(%s, %s)' "$pid" "$rk"
      first=0
    else
      printf ',\n(%s, %s)' "$pid" "$rk"
    fi
    rk=$((rk + 1))
  done <<< "$ids"
  printf '\n)\n'
} > "$sql_tmp"

# Optional FTS5 refinement.
fts_join=""
if [ -n "$REFINE_Q" ]; then
  fts_parts=()
  for token in $REFINE_Q; do
    clean="$(printf '%s' "$token" | tr -cd 'a-zA-Z0-9_-')"
    if [ -n "$clean" ]; then
      fts_parts+=("${clean}*")
    fi
  done
  if [ "${#fts_parts[@]}" -gt 0 ]; then
    fts_q="${fts_parts[0]}"
    for i in "${!fts_parts[@]}"; do
      [ "$i" -eq 0 ] && continue
      fts_q="${fts_q} AND ${fts_parts[$i]}"
    done
    sq_fts="$(sql_quote "$fts_q")"
    fts_join="JOIN prompts_fts f ON f.rowid = p.id AND prompts_fts MATCH ${sq_fts}"
  fi
fi

cat >> "$sql_tmp" <<SQL
SELECT p.id, COALESCE(NULLIF(p.display_preview, ''), p.display) AS display, p.project, p.ts, p.pinned
FROM ranked r
JOIN prompts p ON p.id = r.id
${fts_join}
ORDER BY r.rk;
SQL

rows="$(sqlite3 -bail -separator "$RS" -cmd ".timeout 3000" "$CP_DB" < "$sql_tmp" 2>/dev/null || true)"
[ -z "$rows" ] && exit 0

printf '%s\n' "$rows" | cp_render_rows
