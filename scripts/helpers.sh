#!/usr/bin/env bash
# helpers.sh — sourced library. Functions: get_option, require_dep,
# require_dep_version, sql, sql_quote, now_ms, is_tmux, ensure_db.
# Does NOT set -euo pipefail itself because it's sourced; callers set their own.

[ "${CP_HELPERS_LOADED:-}" = "1" ] && return 0
CP_HELPERS_LOADED=1

# Source paths if not already loaded.
_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_helpers_dir}/paths.sh"

# get_option <name> <default>
# Reads a tmux user option if $TMUX is set; otherwise returns <default>.
get_option() {
  local name="$1" default="$2"
  if [ -n "${TMUX:-}" ]; then
    local val
    val="$(tmux show-option -gqv "$name" 2>/dev/null)"
    printf '%s' "${val:-$default}"
  else
    printf '%s' "$default"
  fi
}

# require_dep <cmd>
# Exits 1 with a friendly message if <cmd> is not on PATH.
require_dep() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'claude-prompts: missing required dependency: %s\n' "$cmd" >&2
    printf 'claude-prompts: install %s and try again.\n' "$cmd" >&2
    exit 1
  fi
}

# require_dep_version <cmd> <version_regex>
# Like require_dep but also checks that <cmd> --version output matches <version_regex>.
# Used for fzf ≥ 0.44 in later batches.
require_dep_version() {
  local cmd="$1" regex="$2"
  require_dep "$cmd"
  local ver
  ver="$("$cmd" --version 2>&1 | head -1)"
  if ! printf '%s' "$ver" | grep -qE "$regex"; then
    printf 'claude-prompts: %s version check failed (got: %s)\n' "$cmd" "$ver" >&2
    printf 'claude-prompts: required version pattern: %s\n' "$regex" >&2
    exit 1
  fi
}

# sql "<query>"
# Runs query against $CP_DB with busy_timeout set.
# Exits 2 on sqlite3 error (propagates -bail).
sql() {
  local query="$1"
  sqlite3 -bail -cmd ".timeout 3000" "$CP_DB" "$query"
}

# sql_quote <text>
# Emits an SQLite-safe single-quoted string literal (internal quotes doubled).
# Reads from $1; if empty, reads stdin.
sql_quote() {
  local text
  if [ $# -ge 1 ]; then
    text="$1"
  else
    text="$(cat)"
  fi
  # Double all single-quotes, then wrap in single-quotes.
  local escaped
  escaped="${text//\'/\'\'}"
  printf "'%s'" "$escaped"
}

# now_ms
# Emits current time as milliseconds since Unix epoch.
now_ms() {
  printf '%s' "$(($(date +%s%N) / 1000000))"
}

# is_tmux
# Returns 0 if running inside a tmux session.
is_tmux() {
  [ -n "${TMUX:-}" ]
}

# ensure_db
# Creates $CP_DATA_DIR if needed, applies schema.sql idempotently.
# Uses SQLite PRAGMA user_version to track whether schema was applied:
#   user_version 0 = fresh DB, apply schema; user_version ≥ 1 = already done.
ensure_db() {
  mkdir -p "$CP_DATA_DIR"
  require_dep sqlite3
  local schema_file="${_helpers_dir}/schema.sql"
  # Check current user_version
  local ver
  ver="$(sqlite3 "$CP_DB" "PRAGMA user_version;" 2>/dev/null || printf '0')"
  if [ "${ver:-0}" -eq 0 ]; then
    # Apply schema then bump version to 2 to mark it done.
    if ! sqlite3 -bail "$CP_DB" < "$schema_file" >/dev/null; then
      printf 'claude-prompts: failed to apply schema.sql\n' >&2
      exit 2
    fi
    sqlite3 "$CP_DB" "PRAGMA user_version = 2;" >/dev/null
  elif [ "${ver:-0}" -eq 1 ]; then
    # Migrate v1 → v2: add display_preview column. Idempotent: ignore "duplicate" error.
    sqlite3 "$CP_DB" \
      "ALTER TABLE prompts ADD COLUMN display_preview TEXT NOT NULL DEFAULT '';" \
      >/dev/null 2>&1 || true
    sqlite3 "$CP_DB" "PRAGMA user_version = 2;" >/dev/null
  fi
}
