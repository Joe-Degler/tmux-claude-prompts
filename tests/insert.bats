#!/usr/bin/env bats
# tests/insert.bats — 6 cases testing insert.sh / resolve.sh behavior.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
  export TMUX_LOG_FILE="$TEST_TMP/tmux.log"
}

teardown() {
  teardown_fixtures
}

# Helper: query DB
db_query() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" "$1"
}

# Helper: get the id for a prompt by its display_full (with literal newlines)
db_id_for() {
  local display_full="$1"
  sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT id FROM prompts WHERE display_full = '${display_full//\'/\'\'}';"
}

# Case 1: marker replacement produces full text
# api-service paste-only row: display_full = '[Pasted text #1 +3 lines]'
# paste content = "def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew"
@test "marker replacement produces full text" {
  local id
  id="$(db_id_for '[Pasted text #1 +3 lines]')"

  local expected
  expected="$(printf 'def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew')"

  run bash "${CP_ROOT}/scripts/resolve.sh" "$id"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# Case 2: multiple markers replaced in one prompt
# playbook row: "Look at this:\n[Pasted text #1 +5 lines]\nand also [Pasted text #2 +2 lines]"
@test "multiple markers replaced in one prompt" {
  local id
  id="$(db_id_for 'Look at this:
[Pasted text #1 +5 lines]
and also [Pasted text #2 +2 lines]')"

  run bash "${CP_ROOT}/scripts/resolve.sh" "$id"
  [ "$status" -eq 0 ]

  # Must contain prose text
  [[ "$output" == *"Look at this:"* ]]
  [[ "$output" == *"and also"* ]]

  # Must contain paste #1 content
  [[ "$output" == *"line a"* ]]
  [[ "$output" == *"line e"* ]]

  # Must contain paste #2 content
  [[ "$output" == *"ENOENT"* ]]
  [[ "$output" == *"ETIMEDOUT"* ]]

  # No marker strings should remain
  [[ "$output" != *"[Pasted text #"* ]]
}

# Case 3: paste-literal mode preserves markers (with fake tmux)
@test "literal mode preserves markers" {
  local id
  id="$(db_id_for '[Pasted text #1 +3 lines]')"

  local mock_dir
  mock_dir="$(mock_tmux_dir)"

  export TMUX_LOG_FILE="$TEST_TMP/tmux_literal.log"
  run env \
    TMUX="/tmp/fake-tmux-session" \
    ORIG_PANE="%88" \
    PATH="${mock_dir}:${PATH}" \
    bash "${CP_ROOT}/scripts/insert.sh" paste-literal "$id"
  [ "$status" -eq 0 ]

  [ -f "$TMUX_LOG_FILE" ]
  local log
  log="$(cat "$TMUX_LOG_FILE")"

  [[ "$log" == *"send-keys"* ]]
  [[ "$log" == *" -l "* ]]
  [[ "$log" == *"%88"* ]]

  # Reconstruct the typed text from per-char send-keys invocations.
  local typed
  typed="$(awk '
    /send-keys.*-- / {
      i = index($0, " -- ")
      if (i > 0) printf "%s", substr($0, i + 4)
    }
  ' "$TMUX_LOG_FILE")"
  [[ "$typed" == "[Pasted text #1 +3 lines]" ]]
}

# Case 4: paste action with no paste rows is identity
# /init row has no pastedContents — resolve.sh should return display_full unchanged
@test "paste action with no paste rows is identity" {
  local id
  id="$(db_id_for '/init what should the schema look like')"

  local expected
  expected="$(db_query "SELECT display_full FROM prompts WHERE id=${id};")"

  run bash "${CP_ROOT}/scripts/resolve.sh" "$id"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# Case 5: unmatched marker is replaced by [Pasted Text Lost]
@test "unmatched marker becomes [Pasted Text Lost]" {
  # Insert a synthetic row with a marker that has no matching paste row.
  local fake_hash="aabbccddeeff00112233445566778899aabbccdd"
  local fake_display="Check [Pasted text #99 +0 lines] for details"
  sqlite3 "$CP_DB" <<SQL
INSERT INTO prompts(display, display_full, project, ts, hash)
VALUES('${fake_display//\'/\'\'}', '${fake_display//\'/\'\'}', '/test/unmatched', 9999999999000, '${fake_hash}');
SQL

  local id
  id="$(db_query "SELECT id FROM prompts WHERE hash='${fake_hash}';")"

  run bash "${CP_ROOT}/scripts/resolve.sh" "$id"
  # exit 2 still signals "had a lost paste" — caller (insert.sh) uses it to warn
  [ "$status" -eq 2 ]
  # User must never see the raw marker; it's swapped for a friendly label.
  [[ "$output" == *"[Pasted Text Lost]"* ]]
  [[ "$output" != *"[Pasted text #99"* ]]
}

# Case 6: tmux insert per-character via send-keys -l (defeats burst detection)
@test "tmux insert types text char-by-char via send-keys -l" {
  local id
  id="$(db_id_for '/init what should the schema look like')"

  local mock_dir
  mock_dir="$(mock_tmux_dir)"
  export TMUX_LOG_FILE="$TEST_TMP/tmux_insert.log"

  run env \
    TMUX="/tmp/fake-tmux-session" \
    ORIG_PANE="%99" \
    PATH="${mock_dir}:${PATH}" \
    bash "${CP_ROOT}/scripts/insert.sh" paste "$id"
  [ "$status" -eq 0 ]

  [ -f "$TMUX_LOG_FILE" ]
  local log
  log="$(cat "$TMUX_LOG_FILE")"

  # Send-keys is invoked at least once on the originating pane (chunked).
  local send_count
  send_count="$(awk '/send-keys/ {n++} END {print n+0}' "$TMUX_LOG_FILE")"
  [ "$send_count" -ge 1 ]
  [[ "$log" == *"%99"* ]]
  [[ "$log" == *" -l "* ]]

  # Reconstruct the typed text by extracting the byte after the trailing '--'
  # in each send-keys ARGV line. The mock logs each arg space-separated.
  local typed
  typed="$(awk '
    /send-keys.*-- / {
      # take everything after " -- "
      i = index($0, " -- ")
      if (i > 0) printf "%s", substr($0, i + 4)
    }
  ' "$TMUX_LOG_FILE")"
  [[ "$typed" == "/init what should the schema look like" ]]
}
