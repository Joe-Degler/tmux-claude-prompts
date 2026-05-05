#!/usr/bin/env bash
# query.sh — emit fzf-formatted rows for a given query string.
# Usage: query.sh "<query string>"
# Output: <id>\x1f<ANSI-rendered-line>\n per row.
# Reads scope from $CP_SCOPE_FILE (default: everywhere).
# Reads $ORIG_PATH for project chip when scope is everywhere.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"
. "${SCRIPT_DIR}/render.sh"

require_dep sqlite3

Q="${1:-}"

# --- Read scope ---
scope="everywhere"
if [ -f "$CP_SCOPE_FILE" ]; then
  scope="$(cat "$CP_SCOPE_FILE")"
fi
[ -z "$scope" ] && scope="everywhere"

if [ "$scope" = "everywhere" ]; then
  proj_filter=""
else
  proj_filter="$scope"
fi

# --- Read case-sensitivity mode (default: insensitive) ---
case_mode="insensitive"
if [ -f "$CP_CASE_FILE" ]; then
  case_mode="$(cat "$CP_CASE_FILE")"
fi
[ -z "$case_mode" ] && case_mode="insensitive"

# --- Build FTS query (only used in case-insensitive mode) ---
fts_query=""
use_fts=0
use_like=0
use_sensitive=0

if [ -n "$Q" ]; then
  if [ "$case_mode" = "sensitive" ]; then
    # Case-sensitive: skip FTS (its tokenizer normalizes case) and use instr().
    use_sensitive=1
  else
    # Sanitize: keep only alnum, underscore, hyphen; split on whitespace
    # Build FTS query tokens: each token appended with *
    fts_parts=()
    for token in $Q; do
      # Strip chars that aren't alnum, _, -
      clean="$(printf '%s' "$token" | tr -cd 'a-zA-Z0-9_-')"
      if [ -n "$clean" ]; then
        fts_parts+=("${clean}*")
      fi
    done

    if [ "${#fts_parts[@]}" -gt 0 ]; then
      # AND-join the tokens
      fts_query="${fts_parts[0]}"
      for i in "${!fts_parts[@]}"; do
        [ "$i" -eq 0 ] && continue
        fts_query="${fts_query} AND ${fts_parts[$i]}"
      done
      use_fts=1
    else
      # Symbols-only query → LIKE fallback
      use_like=1
    fi
  fi
fi

# --- SQL query runner ---
# Returns rows as: id<RS>display<RS>project<RS>ts<RS>pinned<RS>label, RS = 0x1e.
# Pipe ('|') is unsafe because display can contain literal pipes (markdown tables).
RS=$'\x1e'
run_sql() {
  local sql_file="$1"
  sqlite3 -bail -separator "$RS" \
    -cmd ".timeout 3000" \
    "$CP_DB" < "$sql_file" 2>/dev/null
}

# Build the scope filter expression (shared by all queries)
sq_proj="$(sql_quote "$proj_filter")"
sq_q=""

# Write SQL to temp file (avoids argument-length issues with large queries)
sql_tmp="$(mktemp /tmp/cp_query_XXXXXX.sql)"
trap 'rm -f "$sql_tmp"' EXIT

if [ -z "$Q" ]; then
  # BROWSE query
  cat > "$sql_tmp" <<SQL
SELECT id, COALESCE(NULLIF(display_preview, ''), display) AS display, project, ts, pinned, label
FROM prompts
WHERE (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY pinned DESC, ts DESC
LIMIT 500;
SQL
  rows="$(run_sql "$sql_tmp")"

elif [ "$use_sensitive" -eq 1 ]; then
  # Case-sensitive: AND-join token-level instr() checks against display_full
  # and paste_contents.content. instr() is byte-wise (case-sensitive in SQLite).
  where_parts=()
  for token in $Q; do
    [ -z "$token" ] && continue
    sq_tk="$(sql_quote "$token")"
    where_parts+=("(instr(display_full, ${sq_tk}) > 0 OR id IN (SELECT prompt_id FROM paste_contents WHERE instr(content, ${sq_tk}) > 0))")
  done
  if [ "${#where_parts[@]}" -eq 0 ]; then
    # Whitespace-only query — fall through to BROWSE behaviour.
    cat > "$sql_tmp" <<SQL
SELECT id, COALESCE(NULLIF(display_preview, ''), display) AS display, project, ts, pinned, label
FROM prompts
WHERE (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY pinned DESC, ts DESC
LIMIT 500;
SQL
  else
    where_clause="${where_parts[0]}"
    for i in "${!where_parts[@]}"; do
      [ "$i" -eq 0 ] && continue
      where_clause="${where_clause} AND ${where_parts[$i]}"
    done
    cat > "$sql_tmp" <<SQL
SELECT id, COALESCE(NULLIF(display_preview, ''), display) AS display, project, ts, pinned, label
FROM prompts
WHERE ${where_clause}
  AND (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY pinned DESC, ts DESC
LIMIT 200;
SQL
  fi
  rows="$(run_sql "$sql_tmp")"

elif [ "$use_fts" -eq 1 ]; then
  # FTS query — sort recent-first to match BROWSE/LIKE/sensitive paths.
  sq_q="$(sql_quote "$fts_query")"
  cat > "$sql_tmp" <<SQL
SELECT p.id, COALESCE(NULLIF(p.display_preview, ''), p.display) AS display, p.project, p.ts, p.pinned, p.label
FROM prompts_fts f JOIN prompts p ON p.id = f.rowid
WHERE prompts_fts MATCH ${sq_q}
  AND (${sq_proj} = '' OR p.project = ${sq_proj})
ORDER BY p.pinned DESC, p.ts DESC
LIMIT 200;
SQL
  rows="$(run_sql "$sql_tmp")"
  # Check if FTS returned any rows; if empty fall back to LIKE
  if [ -z "$rows" ]; then
    use_like=1
  fi
fi

if [ "${use_like:-0}" -eq 1 ]; then
  # LIKE fallback
  sq_like="$(sql_quote "%${Q}%")"
  cat > "$sql_tmp" <<SQL
SELECT id, COALESCE(NULLIF(display_preview, ''), display) AS display, project, ts, pinned, label
FROM prompts
WHERE display LIKE ${sq_like}
  AND (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY pinned DESC, ts DESC
LIMIT 200;
SQL
  rows="$(run_sql "$sql_tmp")"
fi

[ -z "${rows:-}" ] && exit 0

printf '%s\n' "$rows" | cp_render_rows
