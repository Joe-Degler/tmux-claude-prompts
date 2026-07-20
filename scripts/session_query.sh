#!/usr/bin/env bash
# session_query.sh — emit fzf rows for session-search mode.
# Usage: session_query.sh "<query string>"
# Output: <sid>\x1f<ANSI-rendered-line>\n per row (one row per session).
#
# Search semantics: session_fts holds ONE document per session (all non-tool
# message text), so multi-token queries match across different turns of the
# same conversation. Case-sensitive and LIKE paths scan session_messages with
# role IN ('user','assistant','bash') — tool one-liners are preview-only.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"
. "${SCRIPT_DIR}/helpers.sh"

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
sq_proj="$(sql_quote "$proj_filter")"

# --- Read case-sensitivity mode ---
case_mode="insensitive"
if [ -f "$CP_CASE_FILE" ]; then
  case_mode="$(cat "$CP_CASE_FILE")"
fi
[ -z "$case_mode" ] && case_mode="insensitive"

# --- Build FTS query (case-insensitive mode only; same sanitizing as query.sh) ---
fts_query=""
use_fts=0
use_like=0
use_sensitive=0

# Script IFS excludes space, so word-split the query explicitly.
q_tokens=()
if [ -n "$Q" ]; then
  IFS=$' \t\n' read -r -a q_tokens <<< "$Q"
fi

if [ -n "$Q" ]; then
  if [ "$case_mode" = "sensitive" ]; then
    use_sensitive=1
  else
    fts_parts=()
    for token in "${q_tokens[@]}"; do
      clean="$(printf '%s' "$token" | tr -cd 'a-zA-Z0-9_-')"
      if [ -n "$clean" ]; then
        fts_parts+=("\"${clean}\"*")
      fi
    done
    if [ "${#fts_parts[@]}" -gt 0 ]; then
      fts_query="${fts_parts[0]}"
      for i in "${!fts_parts[@]}"; do
        [ "$i" -eq 0 ] && continue
        fts_query="${fts_query} AND ${fts_parts[$i]}"
      done
      use_fts=1
    else
      use_like=1
    fi
  fi
fi

RS=$'\x1e'
run_sql() {
  local sql_file="$1"
  sqlite3 -bail -separator "$RS" \
    -cmd ".timeout 3000" \
    "$CP_DB" < "$sql_file" 2>/dev/null
}

sql_tmp="$(mktemp /tmp/cp_squery_XXXXXX.sql)"
trap 'rm -f "$sql_tmp"' EXIT

SELECT_COLS="sid, project, last_ts, msg_count, title"

if [ -z "$Q" ]; then
  # BROWSE: recent sessions in scope
  cat > "$sql_tmp" <<SQL
SELECT ${SELECT_COLS}
FROM sessions
WHERE (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY last_ts DESC
LIMIT 200;
SQL
  rows="$(run_sql "$sql_tmp")"

elif [ "$use_sensitive" -eq 1 ]; then
  # Case-sensitive: token-AND instr() over dialogue messages (byte-wise).
  where_parts=()
  for token in "${q_tokens[@]}"; do
    [ -z "$token" ] && continue
    sq_tk="$(sql_quote "$token")"
    where_parts+=("id IN (SELECT session_id FROM session_messages WHERE role IN ('user','assistant','bash') AND instr(text, ${sq_tk}) > 0)")
  done
  if [ "${#where_parts[@]}" -eq 0 ]; then
    cat > "$sql_tmp" <<SQL
SELECT ${SELECT_COLS}
FROM sessions
WHERE (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY last_ts DESC
LIMIT 200;
SQL
  else
    where_clause="${where_parts[0]}"
    for i in "${!where_parts[@]}"; do
      [ "$i" -eq 0 ] && continue
      where_clause="${where_clause} AND ${where_parts[$i]}"
    done
    cat > "$sql_tmp" <<SQL
SELECT ${SELECT_COLS}
FROM sessions
WHERE ${where_clause}
  AND (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY last_ts DESC
LIMIT 200;
SQL
  fi
  rows="$(run_sql "$sql_tmp")"

elif [ "$use_fts" -eq 1 ]; then
  sq_q="$(sql_quote "$fts_query")"
  cat > "$sql_tmp" <<SQL
SELECT s.sid, s.project, s.last_ts, s.msg_count, s.title
FROM session_fts f JOIN sessions s ON s.id = f.rowid
WHERE session_fts MATCH ${sq_q}
  AND (${sq_proj} = '' OR s.project = ${sq_proj})
ORDER BY s.last_ts DESC
LIMIT 200;
SQL
  rows="$(run_sql "$sql_tmp")" || rows=""
  if [ -z "$rows" ]; then
    use_like=1
  fi
fi

if [ "${use_like:-0}" -eq 1 ]; then
  sq_like="$(sql_quote "%${Q}%")"
  cat > "$sql_tmp" <<SQL
SELECT ${SELECT_COLS}
FROM sessions
WHERE (title LIKE ${sq_like}
       OR id IN (SELECT session_id FROM session_messages
                 WHERE role IN ('user','assistant','bash') AND text LIKE ${sq_like}))
  AND (${sq_proj} = '' OR project = ${sq_proj})
ORDER BY last_ts DESC
LIMIT 200;
SQL
  rows="$(run_sql "$sql_tmp")"
fi

[ -z "${rows:-}" ] && exit 0

# --- Render: <sid>\x1f<chip> <title> <dim: msgs · age> ---
ESC=$'\033'
RESET="${ESC}[0m"
ANSI_PROJ_OPEN="$(printf '%s[38;5;%sm' "$ESC" "${GLYPH_COLOR[proj]}")"
NOW_MS="$(now_ms)"
TRUNC="${GLYPHS[trunc]}"

SHOW_CHIP=0
[ "$scope" = "everywhere" ] && SHOW_CHIP=1

while IFS="$RS" read -r sid project last_ts msg_count title; do
  [ -z "$sid" ] && continue

  age_ms=$(( NOW_MS - last_ts ))
  if   [ "$age_ms" -lt 3600000 ];     then rel_time="$(( age_ms/60000 ))m"
  elif [ "$age_ms" -lt 86400000 ];    then rel_time="$(( age_ms/3600000 ))h"
  elif [ "$age_ms" -lt 604800000 ];   then rel_time="$(( age_ms/86400000 ))d"
  elif [ "$age_ms" -lt 2592000000 ];  then rel_time="$(( age_ms/604800000 ))w"
  else rel_time="$(( age_ms/2592000000 ))mo"; fi

  chip_str=""
  if [ "$SHOW_CHIP" -eq 1 ]; then
    chip_name="${project##*/}"
    [ -z "$chip_name" ] && chip_name="?"
    if [ "${#chip_name}" -gt 14 ]; then
      chip_name="${chip_name:0:14}"
    else
      chip_name="${chip_name}              "
      chip_name="${chip_name:0:14}"
    fi
    chip_str="${ANSI_PROJ_OPEN}${chip_name}${RESET}  "
  fi

  disp="$title"
  [ -z "$disp" ] && disp="(untitled session)"
  if [ "${#disp}" -gt 200 ]; then
    disp="${disp:0:200}${TRUNC}"
  fi

  meta_str="$(printf '%s[38;5;244m %s msgs %s %s%s' "$ESC" "$msg_count" "${GLYPHS[warm]}" "$rel_time" "$RESET")"

  printf '%s\x1f%s%s%s\n' "$sid" "$chip_str" "$disp" "$meta_str"
done <<< "$rows"
