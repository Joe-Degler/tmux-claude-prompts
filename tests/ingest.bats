#!/usr/bin/env bats
# tests/ingest.bats — 8 cases testing ingest.sh behavior.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
}

teardown() {
  teardown_fixtures
}

# Helper: run sqlite3 query against the isolated DB
db_query() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" "$1"
}

# Case 1: ingests fresh fixture — 7 rows (9 lines - 1 empty - 1 dup)
@test "ingests fresh fixture" {
  run db_query "SELECT count(*) FROM prompts;"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

# Case 2: idempotent on second run — row count unchanged, byte_offset advanced once
@test "is idempotent on second run" {
  # Get byte_offset after first ingest (done in setup_db)
  offset_first="$(db_query "SELECT value FROM ingest_state WHERE key='byte_offset';")"

  # Run ingest a second time (no --force, so it's incremental)
  run bash "${CP_ROOT}/scripts/ingest.sh"
  [ "$status" -eq 0 ]

  # Row count still 7
  count="$(db_query "SELECT count(*) FROM prompts;")"
  [ "$count" = "7" ]

  # byte_offset should be same as after first run (no new bytes)
  offset_second="$(db_query "SELECT value FROM ingest_state WHERE key='byte_offset';")"
  [ "$offset_first" = "$offset_second" ]
}

# Case 3: paste-marker-only display row IS present (not skipped)
@test "skips empty display only (NOT paste markers)" {
  # The [Pasted text #1 +3 lines] row for api-service should be in prompts
  run db_query "SELECT count(*) FROM prompts WHERE display_full = '[Pasted text #1 +3 lines]';"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# Case 4: paste_contents table has 3 rows (1 api-service + 2 multi-paste playbook)
@test "ingests paste contents into paste_contents table" {
  run db_query "SELECT count(*) FROM paste_contents;"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# Case 5: duplicate /init rows — max(ts) kept
@test "keeps max(ts) on duplicate" {
  run db_query "SELECT ts FROM prompts WHERE display_full = '/init what should the schema look like';"
  [ "$status" -eq 0 ]
  [ "$output" = "1714780500000" ]
}

# Case 6: newlines collapsed to ↵ marker in display column
@test "collapses newlines into ↵ marker" {
  # The dotfiles row has 3 lines — display should contain ↵ not raw newlines
  display="$(db_query "SELECT display FROM prompts WHERE project = '/home/joedegler/dotfiles';")"
  # Must contain the ↵ character (U+21B5, UTF-8: e2 86 b5)
  [[ "$display" == *"↵"* ]]
  # Must NOT contain a raw newline
  [[ "$display" != *$'\n'* ]]
}

# Case 7: incremental ingest picks up new lines
@test "incremental ingest picks up new lines" {
  # Current count
  count_before="$(db_query "SELECT count(*) FROM prompts;")"

  # Append a unique 10th line to a copy of the fixture
  local extra_fixture="$TEST_TMP/extra.jsonl"
  cp "$HOME/.claude/history.jsonl" "$extra_fixture"
  printf '%s\n' '{"display":"brand new unique prompt xyz987","project":"/opt/development/new-project","timestamp":1714790000000,"pastedContents":{}}' >> "$extra_fixture"

  # Run incremental ingest with the extended fixture
  CP_HISTORY="$extra_fixture" bash "${CP_ROOT}/scripts/ingest.sh" >/dev/null

  count_after="$(db_query "SELECT count(*) FROM prompts;")"
  [ "$count_after" = "$((count_before + 1))" ]
}

# Case 8: paste contents survive re-ingest
@test "paste contents survive re-ingest" {
  count_first="$(db_query "SELECT count(*) FROM paste_contents;")"

  # Run --force again (full re-ingest)
  bash "${CP_ROOT}/scripts/ingest.sh" --force >/dev/null

  count_second="$(db_query "SELECT count(*) FROM paste_contents;")"
  [ "$count_first" = "$count_second" ]
  [ "$count_second" = "3" ]
}

# Case 9: marker-only display gets a snippet preview from its paste content.
# Fixture row '[Pasted text #1 +3 lines]' with content
# 'def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew'
# should produce display_preview that starts with 'def refresh_token():'
# and contains the ↵ collapse marker.
@test "marker-only row gets paste-content snippet as display_preview" {
  preview="$(db_query "SELECT display_preview FROM prompts WHERE display_full = '[Pasted text #1 +3 lines]';")"
  [[ "$preview" == def\ refresh_token* ]]
  [[ "$preview" == *"↵"* ]]
  # Original marker must NOT appear in the preview
  [[ "$preview" != *"[Pasted text #"* ]]
}

# Case 10: rows that aren't pure markers keep display as preview (newline-collapsed).
@test "non-marker row preview equals collapsed display" {
  preview="$(db_query "SELECT display_preview FROM prompts WHERE display_full = 'Fix the auth middleware so tokens refresh before expiry';")"
  [ "$preview" = "Fix the auth middleware so tokens refresh before expiry" ]
}
