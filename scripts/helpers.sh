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
    # Apply schema then bump version to 6 to mark it done.
    if ! sqlite3 -bail "$CP_DB" < "$schema_file" >/dev/null; then
      printf 'claude-prompts: failed to apply schema.sql\n' >&2
      exit 2
    fi
    sqlite3 "$CP_DB" "PRAGMA user_version = 6;" >/dev/null
  elif [ "${ver:-0}" -eq 1 ]; then
    # Migrate v1 → v2: add display_preview column. Idempotent: ignore "duplicate" error.
    sqlite3 "$CP_DB" \
      "ALTER TABLE prompts ADD COLUMN display_preview TEXT NOT NULL DEFAULT '';" \
      >/dev/null 2>&1 || true
    sqlite3 "$CP_DB" "PRAGMA user_version = 2;" >/dev/null
    ver=2
  fi
  if [ "${ver:-0}" -eq 2 ]; then
    # v2 → v3: display_preview is now computed with paste content inlined
    # (no raw `[Pasted text #N]` markers). Run a stdlib-only Python pass
    # to rewrite every existing row's preview in one go — much faster
    # than a full re-ingest and synchronous enough not to block the popup.
    if command -v python3 >/dev/null 2>&1; then
      CP_DB="$CP_DB" python3 "${_helpers_dir}/rebuild_previews.py" >&2 || true
    fi
    sqlite3 "$CP_DB" "PRAGMA user_version = 3;" >/dev/null
    ver=3
  fi
  # Re-read the version because the v2→v3 path above bumped it.
  ver="$(sqlite3 "$CP_DB" "PRAGMA user_version;" 2>/dev/null || printf '0')"
  if [ "${ver:-0}" -eq 3 ]; then
    # v3 → v4: introduce groups, group_members, prompts.label, and a 2-column
    # FTS5 (body, label). Three sqlite3 invocations:
    #   (1) groups + group_members + index in one transaction
    #   (2) ALTER TABLE prompts ADD COLUMN label  (idempotent via `|| true`)
    #   (3) drop+recreate FTS5 with new schema, repopulate, recreate triggers
    sqlite3 -bail "$CP_DB" >/dev/null <<'SQL_GROUPS'
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS groups (
  id   INTEGER PRIMARY KEY,
  name TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  ts   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS group_members (
  group_id  INTEGER NOT NULL REFERENCES groups(id)  ON DELETE CASCADE,
  prompt_id INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
  ts        INTEGER NOT NULL,
  PRIMARY KEY (group_id, prompt_id)
);
CREATE INDEX IF NOT EXISTS idx_group_members_prompt ON group_members(prompt_id);
SQL_GROUPS

    # ALTER TABLE in its own invocation so re-running after partial failure
    # doesn't blow up on "duplicate column".
    sqlite3 "$CP_DB" \
      "ALTER TABLE prompts ADD COLUMN label TEXT NULL;" \
      >/dev/null 2>&1 || true

    sqlite3 -bail "$CP_DB" >/dev/null <<'SQL_FTS'
DROP TRIGGER IF EXISTS prompts_ai;
DROP TRIGGER IF EXISTS prompts_ad;
DROP TRIGGER IF EXISTS prompts_au;
DROP TRIGGER IF EXISTS prompts_au_label;
DROP TRIGGER IF EXISTS paste_ai;
DROP TRIGGER IF EXISTS paste_au;
DROP TRIGGER IF EXISTS paste_ad;
DROP TABLE IF EXISTS prompts_fts;
CREATE VIRTUAL TABLE prompts_fts USING fts5(
  body,
  label,
  tokenize='unicode61 remove_diacritics 2'
);
INSERT INTO prompts_fts(rowid, body, label)
SELECT p.id,
       p.display || char(10) || COALESCE(
         (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
         ''
       ),
       COALESCE(p.label, '')
FROM prompts p;

CREATE TRIGGER prompts_ai AFTER INSERT ON prompts BEGIN
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;
CREATE TRIGGER prompts_ad AFTER DELETE ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
END;
CREATE TRIGGER prompts_au AFTER UPDATE OF display ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;
CREATE TRIGGER prompts_au_label AFTER UPDATE OF label ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;
CREATE TRIGGER paste_ai AFTER INSERT ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = new.prompt_id;
END;
CREATE TRIGGER paste_au AFTER UPDATE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = new.prompt_id;
END;
CREATE TRIGGER paste_ad AFTER DELETE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = old.prompt_id;
END;
PRAGMA user_version = 4;
SQL_FTS
    ver=4
  fi
  # Re-read in case the v3→v4 path bumped it (or a previous run left us
  # at v4 and we just need the v5 backfill).
  ver="$(sqlite3 "$CP_DB" "PRAGMA user_version;" 2>/dev/null || printf '0')"
  if [ "${ver:-0}" -eq 4 ]; then
    if command -v python3 >/dev/null 2>&1; then
      CP_DB="$CP_DB" python3 "${_helpers_dir}/backfill_session_pastes.py" >&2 || true
    fi
    sqlite3 "$CP_DB" "PRAGMA user_version = 5;" >/dev/null
    ver=5
  fi
  # v5 → v6: backfill_session_pastes.py grew a paste-cache reader. Re-run
  # it to pick up rows that v5 left as [Pasted Text Lost] because their
  # `pastedContents` carried `contentHash` references rather than inline
  # bodies. Idempotent: rows already repaired no longer match the LIKE.
  if [ "${ver:-0}" -eq 5 ]; then
    if command -v python3 >/dev/null 2>&1; then
      CP_DB="$CP_DB" python3 "${_helpers_dir}/backfill_session_pastes.py" >&2 || true
    fi
    sqlite3 "$CP_DB" "PRAGMA user_version = 6;" >/dev/null
    ver=6
  fi
}
