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

# Case 1: ingests fresh fixture — 11 rows (13 lines - 1 empty - 1 dup)
@test "ingests fresh fixture" {
  run db_query "SELECT count(*) FROM prompts;"
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
}

# Case 2: idempotent on second run — row count unchanged, byte_offset advanced once
@test "is idempotent on second run" {
  # Get byte_offset after first ingest (done in setup_db)
  offset_first="$(db_query "SELECT value FROM ingest_state WHERE key='byte_offset';")"

  # Run ingest a second time (no --force, so it's incremental)
  run bash "${CP_ROOT}/scripts/ingest.sh"
  [ "$status" -eq 0 ]

  # Row count still 11
  count="$(db_query "SELECT count(*) FROM prompts;")"
  [ "$count" = "11" ]

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

# Case 4: paste_contents table has 6 rows (1 api-service + 2 multi-paste
# playbook + 2 from session-fallback + 1 from contentHash paste-cache)
@test "ingests paste contents into paste_contents table" {
  run db_query "SELECT count(*) FROM paste_contents;"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
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
  [ "$count_second" = "6" ]
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

# Case 11: session JSONL fallback recovers paste bodies when history.jsonl
# carries empty pastedContents:{} (current Claude Code format).
@test "session fallback populates paste_contents for new-format entry" {
  prompt_id="$(db_query "SELECT id FROM prompts WHERE ts = 1761930548563;")"
  [ -n "$prompt_id" ]
  count="$(db_query "SELECT count(*) FROM paste_contents WHERE prompt_id = $prompt_id;")"
  [ "$count" = "2" ]
  body1="$(db_query "SELECT content FROM paste_contents WHERE prompt_id = $prompt_id AND paste_id = 1;")"
  [ "$body1" = "body-1-line-a
body-1-line-b" ]
  body2="$(db_query "SELECT content FROM paste_contents WHERE prompt_id = $prompt_id AND paste_id = 2;")"
  [ "$body2" = "body-2-only-line" ]
}

@test "display_preview for new-format entry inlines paste bodies" {
  preview="$(db_query "SELECT display_preview FROM prompts WHERE ts = 1761930548563;")"
  [[ "$preview" == *"body-1-line-a"* ]]
  [[ "$preview" == *"body-2-only-line"* ]]
  [[ "$preview" != *"[Pasted Text Lost]"* ]]
  [[ "$preview" != *"[Pasted text #"* ]]
}

@test "session file missing falls through to [Pasted Text Lost]" {
  preview="$(db_query "SELECT display_preview FROM prompts WHERE ts = 1761930600000;")"
  [[ "$preview" == *"[Pasted Text Lost]"* ]]
}

# Case 14: v4 → v5 migration runs the backfill helper, repairs an existing
# `[Pasted Text Lost]` row from a session JSONL, and bumps user_version.
@test "v4 to v5 migration backfills lost-paste rows from session jsonl" {
  # The setup_db fixture path already populated the DB at v5; we want to
  # simulate a pre-v5 state with a lost-paste row, then run the backfill.
  # Stage a fake "v4-state" row by direct SQL:
  #   - display_full has paste markers
  #   - display_preview already contains [Pasted Text Lost]
  #   - ts/project/sessionId align with our existing session JSONL fixture
  display_full=$'check this:\n[Pasted text #1 +2 lines]\nand also [Pasted text #2 +1 lines]'
  # Use a unique ts/hash so the row isn't already present.
  ts=1761930549999
  hash="backfilltest1234567890abcdef0000aaaaaaaa"
  display="${display_full//$'\n'/ ↵ }"
  preview="check this: ↵ [Pasted Text Lost] ↵ and also [Pasted Text Lost]"
  sqlite3 "$CP_DB" \
    "INSERT INTO prompts(display, display_full, display_preview, project, ts, hash) \
     VALUES('${display//\'/\'\'}', '${display_full//\'/\'\'}', '${preview//\'/\'\'}', \
            '/opt/development/playbook', ${ts}, '${hash}');"

  # Append a corresponding history.jsonl entry that points to the existing
  # session fixture (test-session-abc123) at a near-matching timestamp.
  printf '%s\n' \
    "{\"display\":\"check this:\\n[Pasted text #1 +2 lines]\\nand also [Pasted text #2 +1 lines]\",\"pastedContents\":{},\"timestamp\":${ts},\"project\":\"/opt/development/playbook\",\"sessionId\":\"test-session-abc123\",\"hash\":\"${hash}\"}" \
    >> "$HOME/.claude/history.jsonl"

  # Pre-stamp the DB at user_version=4 so the v4→v5 migration block fires.
  sqlite3 "$CP_DB" "PRAGMA user_version = 4;"

  # Re-source helpers.sh in a subshell and call ensure_db so the migration
  # runs end-to-end (including the backfill helper invocation).
  (
    unset CP_HELPERS_LOADED
    . "${CP_ROOT}/scripts/helpers.sh"
    ensure_db
  )

  # Assert: user_version bumped through v4→v5→v6→v7
  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "7" ]

  # Assert: row's preview no longer contains [Pasted Text Lost] and now
  # carries the recovered body text.
  preview_after="$(db_query "SELECT display_preview FROM prompts WHERE ts = ${ts};")"
  [[ "$preview_after" != *"[Pasted Text Lost]"* ]]
  [[ "$preview_after" == *"body-1-line-a"* ]]
  [[ "$preview_after" == *"body-2-only-line"* ]]

  # Assert: paste_contents rows exist for the repaired prompt.
  prompt_id="$(db_query "SELECT id FROM prompts WHERE ts = ${ts};")"
  count="$(db_query "SELECT count(*) FROM paste_contents WHERE prompt_id = ${prompt_id};")"
  [ "$count" = "2" ]
}

# Case 15: live ingest path resolves `contentHash` references via the
# ~/.claude/paste-cache/<hash>.txt file.
@test "ingest resolves contentHash via paste-cache file" {
  prompt_id="$(db_query "SELECT id FROM prompts WHERE ts = 1761930700000;")"
  [ -n "$prompt_id" ]
  body="$(db_query "SELECT content FROM paste_contents WHERE prompt_id = $prompt_id AND paste_id = 1;")"
  [ "$body" = "cached-body-line-1
cached-body-line-2
cached-body-line-3" ]
  preview="$(db_query "SELECT display_preview FROM prompts WHERE id = $prompt_id;")"
  [[ "$preview" == *"cached-body-line-1"* ]]
  [[ "$preview" != *"[Pasted Text Lost]"* ]]
  [[ "$preview" != *"[Pasted text #"* ]]
}

# Case 16: contentHash present but paste-cache file missing → graceful
# fall through to [Pasted Text Lost], no spurious paste_contents row.
@test "missing paste-cache file falls through to [Pasted Text Lost]" {
  prompt_id="$(db_query "SELECT id FROM prompts WHERE ts = 1761930800000;")"
  [ -n "$prompt_id" ]
  preview="$(db_query "SELECT display_preview FROM prompts WHERE id = $prompt_id;")"
  [[ "$preview" == *"[Pasted Text Lost]"* ]]
  count="$(db_query "SELECT count(*) FROM paste_contents WHERE prompt_id = $prompt_id;")"
  [ "$count" = "0" ]
}

# Case 17: v5 → v6 migration re-runs backfill_session_pastes.py to repair
# rows whose history entries carry contentHash references.
@test "v5 to v6 migration backfills lost-paste rows from paste-cache" {
  display_full=$'hash format:\n[Pasted text #1 +2 lines]'
  ts=1761930750000
  hash="cachebackfill1234567890abcdef0000bbbbbb"
  display="${display_full//$'\n'/ ↵ }"
  preview="hash format: ↵ [Pasted Text Lost]"
  sqlite3 "$CP_DB" \
    "INSERT INTO prompts(display, display_full, display_preview, project, ts, hash) \
     VALUES('${display//\'/\'\'}', '${display_full//\'/\'\'}', '${preview//\'/\'\'}', \
            '/opt/development/playbook', ${ts}, '${hash}');"

  # Add a history.jsonl entry referencing the existing fixture paste-cache
  # file (abc123def456) at a near-matching timestamp.
  printf '%s\n' \
    "{\"display\":\"hash format:\\n[Pasted text #1 +2 lines]\",\"pastedContents\":{\"1\":{\"id\":1,\"type\":\"text\",\"contentHash\":\"abc123def456\"}},\"timestamp\":${ts},\"project\":\"/opt/development/playbook\",\"sessionId\":\"hash-backfill-session\",\"hash\":\"${hash}\"}" \
    >> "$HOME/.claude/history.jsonl"

  # Pre-stamp the DB at user_version=5 so only the v5→v6 path fires.
  sqlite3 "$CP_DB" "PRAGMA user_version = 5;"

  (
    unset CP_HELPERS_LOADED
    . "${CP_ROOT}/scripts/helpers.sh"
    ensure_db
  )

  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "7" ]

  preview_after="$(db_query "SELECT display_preview FROM prompts WHERE ts = ${ts};")"
  [[ "$preview_after" != *"[Pasted Text Lost]"* ]]
  [[ "$preview_after" == *"cached-body-line-1"* ]]

  prompt_id="$(db_query "SELECT id FROM prompts WHERE ts = ${ts};")"
  count="$(db_query "SELECT count(*) FROM paste_contents WHERE prompt_id = ${prompt_id};")"
  [ "$count" = "1" ]
}

# Case 18: confirm the v4→v6 migration genuinely visits v5 first (catches a
# regression where the v4→v5 bump is removed and the v5→v6 path silently
# papers over it). We do this by intercepting `backfill_session_pastes.py`
# with a shim that records the DB user_version each time it's invoked.
# After ensure_db on a v4-stamped DB, the recording must show two
# invocations whose seen-versions are 4 then 5.
@test "v4 to v6 migration ladder visits v5 before v6" {
  # Stage a tiny shim wrapper that delegates to the real script but first
  # appends the current user_version to a log file. The shim lives in a
  # tempdir we prepend to PATH so it intercepts `python3 .../backfill...`.
  local shim_dir log_file
  shim_dir="$TEST_TMP/shim"
  log_file="$TEST_TMP/migration.log"
  mkdir -p "$shim_dir"

  # Override helpers.sh's invocation by wrapping python3 itself: the shim
  # detects the backfill_session_pastes.py argv and logs the DB version
  # before delegating.
  cat > "$shim_dir/python3" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == *backfill_session_pastes.py ]]; then
    /usr/bin/env sqlite3 "\$CP_DB" 'PRAGMA user_version;' >> "$log_file"
    break
  fi
done
exec /usr/bin/python3 "\$@"
SHIM
  chmod +x "$shim_dir/python3"

  # Pre-stamp v4 and run ensure_db with the shim on PATH.
  sqlite3 "$CP_DB" "PRAGMA user_version = 4;"
  (
    export PATH="$shim_dir:$PATH"
    unset CP_HELPERS_LOADED
    . "${CP_ROOT}/scripts/helpers.sh"
    ensure_db
  )

  # Final state must be v7.
  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "7" ]

  # The log must contain TWO invocations: the first sees user_version=4
  # (proving the v4→v5 path fired), the second sees user_version=5
  # (proving the v5→v6 path fired distinctly). If the v4→v5 bump were
  # removed, the second invocation would either not happen (ver stays 4)
  # or also see v4, both of which fail this assertion.
  invocations="$(wc -l < "$log_file" | tr -d ' ')"
  [ "$invocations" = "2" ]
  first="$(sed -n '1p' "$log_file")"
  second="$(sed -n '2p' "$log_file")"
  [ "$first" = "4" ]
  [ "$second" = "5" ]
}
