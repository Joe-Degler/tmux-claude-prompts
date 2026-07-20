#!/usr/bin/env bats
# tests/sessions.bats — session-search mode: ingest, query, mode, insert.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
  # Session transcripts live in a mutable copy so append/truncate tests
  # don't touch the repo fixtures.
  export CP_PROJECTS_DIR="$TEST_TMP/transcripts"
  mkdir -p "$CP_PROJECTS_DIR"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/session-transcripts/." "$CP_PROJECTS_DIR/"
  export AWK=gawk
}

teardown() {
  unset CP_PROJECTS_DIR AWK
  teardown_fixtures
}

db_query() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" "$1"
}

session_ingest() {
  python3 "${CP_ROOT}/scripts/ingest_sessions.py" "$@"
}

SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"
SID_C="33333333-3333-3333-3333-333333333333"

# Case 1: fresh DB lands at v7 with the session tables present.
@test "fresh schema has session tables at v7" {
  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "7" ]
  for t in sessions session_messages session_fts session_files; do
    n="$(db_query "SELECT count(*) FROM sqlite_master WHERE name='$t';")"
    [ "$n" = "1" ]
  done
}

# Case 2: ingest counts — noise records (sidechain, meta, command/caveat,
# bash-stdout, thinking, file-history) are filtered; roles land correctly.
@test "ingest filters noise and assigns roles" {
  session_ingest
  n_sessions="$(db_query 'SELECT count(*) FROM sessions;')"
  [ "$n_sessions" = "2" ]

  rowid_a="$(db_query "SELECT id FROM sessions WHERE sid='$SID_A';")"
  roles="$(db_query "SELECT role FROM session_messages WHERE session_id=$rowid_a ORDER BY seq;" | tr '\n' ' ')"
  [ "$roles" = "user assistant tool bash assistant " ]

  # None of the skipped payloads leaked in.
  leaked="$(db_query "SELECT count(*) FROM session_messages WHERE text LIKE '%noise%' OR text LIKE '%sidechain%' OR text LIKE '%secret internal%';")"
  [ "$leaked" = "0" ]
}

# Case 3: noise-only file produces no session row but is cursor-tracked.
@test "noise-only transcript yields no session row" {
  session_ingest
  n="$(db_query "SELECT count(*) FROM sessions WHERE sid='$SID_C';")"
  [ "$n" = "0" ]
  tracked="$(db_query "SELECT count(*) FROM session_files WHERE path LIKE '%$SID_C%';")"
  [ "$tracked" = "1" ]
}

# Case 4: title = first real user prompt, control chars stripped, ts parsed.
@test "title extraction, sanitization, ISO timestamps" {
  session_ingest
  title="$(db_query "SELECT title FROM sessions WHERE sid='$SID_B';")"
  [ "$title" = "database migration [31mfor widgets" ]
  case "$title" in *$'\033'*) false ;; esac

  first_ts="$(db_query "SELECT first_ts FROM sessions WHERE sid='$SID_A';")"
  last_ts="$(db_query "SELECT last_ts FROM sessions WHERE sid='$SID_A';")"
  [ "$first_ts" -gt 1700000000000 ]
  [ "$last_ts" -gt "$first_ts" ]
}

# Case 5: multi-token FTS matches across DIFFERENT turns of one session.
@test "cross-turn multi-token FTS match" {
  session_ingest
  mkdir -p "$CP_RUN_DIR"; : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" "widgets sprocketize"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SID_B"* ]]
  [[ "$output" != *"$SID_A"* ]]
}

# Case 6: bash-input text is searchable.
@test "bash input is searchable" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" "xyzzyfrobnicate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SID_A"* ]]
}

# Case 7: tool one-liners exist for the preview but never match searches
# (FTS, case-sensitive, or LIKE fallback).
@test "tool rows are preview-only, excluded from all search paths" {
  session_ingest
  rowid_a="$(db_query "SELECT id FROM sessions WHERE sid='$SID_A';")"
  n_tool="$(db_query "SELECT count(*) FROM session_messages WHERE session_id=$rowid_a AND role='tool';")"
  [ "$n_tool" = "1" ]

  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" "rspec"
  [ -z "$output" ]

  printf 'sensitive' > "$CP_CASE_FILE"
  run bash "${CP_ROOT}/scripts/session_query.sh" "rspec"
  [ -z "$output" ]
  rm -f "$CP_CASE_FILE"
}

# Case 8: case-sensitive path is byte-wise.
@test "case-sensitive search distinguishes case" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  printf 'sensitive' > "$CP_CASE_FILE"
  run bash "${CP_ROOT}/scripts/session_query.sh" "Widgets"
  [ -z "$output" ]
  run bash "${CP_ROOT}/scripts/session_query.sh" "widgets"
  [[ "$output" == *"$SID_B"* ]]
  rm -f "$CP_CASE_FILE"
}

# Case 9: scope filters sessions; scope list is mode-aware (only projects
# with rows in the active mode are cyclable).
@test "scope filter and mode-aware scope list" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  printf '%s' "/opt/development/alpha" > "$CP_SCOPE_FILE"
  run bash "${CP_ROOT}/scripts/session_query.sh" ""
  [[ "$output" == *"$SID_A"* ]]
  [[ "$output" != *"$SID_B"* ]]
  rm -f "$CP_SCOPE_FILE"

  # Session mode: session projects only.
  run bash "${CP_ROOT}/scripts/scope.sh" list
  [[ "$output" == *"/opt/development/beta"* ]]
  [[ "$output" != *"/opt/development/playbook"* ]]

  # Prompt mode: prompt projects only.
  rm -f "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/scope.sh" list
  [[ "$output" == *"/opt/development/playbook"* ]]
  [[ "$output" != *"/opt/development/beta"* ]]
}

# Case 9b: switching modes while scoped to a project with zero rows in the
# destination mode falls back to everywhere.
@test "mode switch resets scope absent from destination mode" {
  session_ingest
  # playbook has prompts but no sessions → entering session mode resets.
  printf '%s' "/opt/development/playbook" > "$CP_SCOPE_FILE"
  bash "${CP_ROOT}/scripts/session_mode.sh"
  [ -f "$CP_RUN_DIR/sessions" ]
  [ "$(cat "$CP_SCOPE_FILE")" = "everywhere" ]

  # beta has sessions but no prompts → leaving session mode resets too.
  printf '%s' "/opt/development/beta" > "$CP_SCOPE_FILE"
  bash "${CP_ROOT}/scripts/session_mode.sh"
  [ ! -f "$CP_RUN_DIR/sessions" ]
  [ "$(cat "$CP_SCOPE_FILE")" = "everywhere" ]

  # A scope valid in both modes survives the switch.
  db_query "INSERT INTO prompts(display, display_full, project, ts, hash)
            VALUES('x','x','/opt/development/beta', 1, 'scopetesthash');"
  printf '%s' "/opt/development/beta" > "$CP_SCOPE_FILE"
  bash "${CP_ROOT}/scripts/session_mode.sh"
  [ "$(cat "$CP_SCOPE_FILE")" = "/opt/development/beta" ]
}

# Case 10: browse (empty query) orders by recency.
@test "browse orders sessions by recency" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" ""
  first_line="${lines[0]}"
  [[ "$first_line" == "$SID_B"* ]]
}

# Case 11: incremental append is picked up; FTS body refreshed.
@test "incremental append updates messages and FTS" {
  session_ingest
  before="$(db_query "SELECT msg_count FROM sessions WHERE sid='$SID_A';")"
  printf '%s\n' \
    '{"type":"user","sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/opt/development/alpha","timestamp":"2026-07-18T10:03:00.000Z","message":{"role":"user","content":"now handle the quuxwibble edge case"}}' \
    >> "$CP_PROJECTS_DIR/-opt-development-alpha/$SID_A.jsonl"
  session_ingest
  after="$(db_query "SELECT msg_count FROM sessions WHERE sid='$SID_A';")"
  [ "$after" = "$(( before + 1 ))" ]

  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" "quuxwibble"
  [[ "$output" == *"$SID_A"* ]]
}

# Case 12: a partial (unterminated) final line is NOT consumed; completing
# it later ingests exactly once.
@test "partial final line is deferred until newline-terminated" {
  session_ingest
  f="$CP_PROJECTS_DIR/-opt-development-alpha/$SID_A.jsonl"
  printf '%s' \
    '{"type":"user","sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/opt/development/alpha","timestamp":"2026-07-18T10:04:00.000Z","message":{"role":"user","content":"partial zorbltrailing"}}' \
    >> "$f"
  session_ingest
  n="$(db_query "SELECT count(*) FROM session_messages WHERE text LIKE '%zorbltrailing%';")"
  [ "$n" = "0" ]

  printf '\n' >> "$f"
  session_ingest
  n="$(db_query "SELECT count(*) FROM session_messages WHERE text LIKE '%zorbltrailing%';")"
  [ "$n" = "1" ]
}

# Case 13: repeated runs with no changes are no-ops (idempotent).
@test "unchanged files are skipped idempotently" {
  session_ingest
  snap_before="$(db_query 'SELECT count(*) FROM session_messages;')"
  session_ingest
  session_ingest
  snap_after="$(db_query 'SELECT count(*) FROM session_messages;')"
  [ "$snap_before" = "$snap_after" ]
}

# Case 14: shrunken/rewritten file is re-ingested from scratch.
@test "rewritten transcript is re-ingested" {
  session_ingest
  f="$CP_PROJECTS_DIR/-opt-development-beta/$SID_B.jsonl"
  printf '%s\n' \
    '{"type":"user","sessionId":"22222222-2222-2222-2222-222222222222","cwd":"/opt/development/beta","timestamp":"2026-07-19T09:05:00.000Z","message":{"role":"user","content":"rewritten fnordbaz transcript"}}' \
    > "$f"
  session_ingest
  count="$(db_query "SELECT msg_count FROM sessions WHERE sid='$SID_B';")"
  [ "$count" = "1" ]
  gone="$(db_query "SELECT count(*) FROM session_messages WHERE text LIKE '%sprocketize%';")"
  [ "$gone" = "0" ]
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/session_query.sh" "fnordbaz"
  [[ "$output" == *"$SID_B"* ]]
}

# Case 15: deleting a transcript reconciles the session away.
@test "deleted transcript is reconciled out of the index" {
  session_ingest
  rm "$CP_PROJECTS_DIR/-opt-development-beta/$SID_B.jsonl"
  session_ingest
  n="$(db_query "SELECT count(*) FROM sessions WHERE sid='$SID_B';")"
  [ "$n" = "0" ]
  n_fts="$(db_query "SELECT count(*) FROM session_fts WHERE session_fts MATCH 'sprocketize';")"
  [ "$n_fts" = "0" ]
}

# Case 16: --force re-ingests to identical state.
@test "force re-ingest is stable" {
  session_ingest
  before="$(db_query 'SELECT count(*) FROM session_messages;')"
  session_ingest --force
  after="$(db_query 'SELECT count(*) FROM session_messages;')"
  [ "$before" = "$after" ]
}

# Case 17: session_mode.sh toggles the state file and clears group/similar.
@test "session mode toggle clears prompt-mode filters" {
  mkdir -p "$CP_RUN_DIR"
  printf '1' > "$CP_RUN_DIR/group"
  printf '1' > "$CP_RUN_DIR/similar"
  bash "${CP_ROOT}/scripts/session_mode.sh"
  [ -f "$CP_RUN_DIR/sessions" ]
  [ ! -f "$CP_RUN_DIR/group" ]
  [ ! -f "$CP_RUN_DIR/similar" ]
  bash "${CP_ROOT}/scripts/session_mode.sh"
  [ ! -f "$CP_RUN_DIR/sessions" ]
}

# Case 18: dispatch routes to session_query.sh when the mode file exists.
@test "dispatch routes to session query in session mode" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/dispatch.sh" ""
  [[ "$output" == *"$SID_A"* ]]
  [[ "$output" == *"$SID_B"* ]]
}

# Case 19: insert types "/resume <sid>" via send-keys -l with NO newline
# (no Enter reaches the pane).
@test "insert emits /resume without executing" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  local dir
  dir="$(mock_tmux_dir)"
  export TMUX_LOG_FILE="$TEST_TMP/tmux.log"
  : > "$TMUX_LOG_FILE"
  TMUX="fake" ORIG_PANE="%1" PATH="$dir:$PATH" \
    bash "${CP_ROOT}/scripts/insert.sh" paste "$SID_A"
  run cat "$TMUX_LOG_FILE"
  [[ "$output" == *"send-keys -t %1 -l -- /resume $SID_A"* ]]
  # Exactly one send-keys call — no separate newline write.
  n="$(ALLOW_BUILTIN_COMMAND=true grep -c 'send-keys' "$TMUX_LOG_FILE" || true)"
  [ "$n" = "1" ]
}

# Case 20: insert rejects malformed session ids.
@test "insert validates session id format" {
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/insert.sh" paste 'evil; rm -rf /'
  [ "$status" -ne 0 ]
}

# Case 21: curation keys are inert in session mode (uuid ids never reach
# the numeric validators).
@test "curation scripts no-op in session mode" {
  : > "$CP_RUN_DIR/sessions"
  run bash "${CP_ROOT}/scripts/pin.sh" "$SID_A"
  [ "$status" -eq 0 ]
  run bash "${CP_ROOT}/scripts/similar_toggle.sh" "$SID_A"
  [ "$status" -eq 0 ]
  [ ! -f "$CP_RUN_DIR/similar" ]
  run bash "${CP_ROOT}/scripts/action_palette.sh" "$SID_A" delete
  [ "$status" -eq 0 ]
}

# Case 22: preview renders header, /resume line, turns and tool one-liner;
# empty selection is graceful.
@test "session preview renders transcript tail" {
  session_ingest
  : > "$CP_RUN_DIR/sessions"
  export CLAUDE_PROMPTS_NO_NERD=1
  run bash "${CP_ROOT}/scripts/session_preview.sh" "$SID_A" "login"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/resume $SID_A"* ]]
  [[ "$output" == *"please fix the flaky login test"* ]]
  [[ "$output" == *"Bash: bundle exec rspec"* ]]
  [[ "$output" == *"cookie is refreshed"* ]]

  run bash "${CP_ROOT}/scripts/session_preview.sh" "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no session selected)"* ]]
}

# Case 23: v6 → v7 migration creates the session tables on an existing DB.
@test "v6 to v7 migration adds session tables" {
  sqlite3 "$CP_DB" "DROP TABLE sessions; DROP TABLE session_messages; DROP TABLE session_files;"
  sqlite3 "$CP_DB" "DROP TABLE session_fts;"
  sqlite3 "$CP_DB" "PRAGMA user_version = 6;"
  (
    unset CP_HELPERS_LOADED
    . "${CP_ROOT}/scripts/helpers.sh"
    ensure_db
  )
  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "7" ]
  for t in sessions session_messages session_fts session_files; do
    n="$(db_query "SELECT count(*) FROM sqlite_master WHERE name='$t';")"
    [ "$n" = "1" ]
  done
}
