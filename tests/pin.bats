#!/usr/bin/env bats
# tests/pin.bats — 5 cases testing pin.sh behavior.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
}

teardown() {
  teardown_fixtures
}

# Helper: query DB
db_query() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" "$1"
}

# Case 1: first call toggles pinned=1, pinned_at NOT NULL
@test "toggles pinned column on first call" {
  run bash "${CP_ROOT}/scripts/pin.sh" 1
  [ "$status" -eq 0 ]

  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=1;")"
  pinned_at="$(db_query "SELECT pinned_at FROM prompts WHERE id=1;")"

  [ "$pinned" = "1" ]
  [ -n "$pinned_at" ]
}

# Case 2: second call toggles back to pinned=0, pinned_at NULL
@test "toggles back on second call" {
  bash "${CP_ROOT}/scripts/pin.sh" 1
  run bash "${CP_ROOT}/scripts/pin.sh" 1
  [ "$status" -eq 0 ]

  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=1;")"
  pinned_at="$(db_query "SELECT pinned_at FROM prompts WHERE id=1;")"

  [ "$pinned" = "0" ]
  [ -z "$pinned_at" ]
}

# Case 3: pinned rows sort before unpinned in browse query
@test "pinned rows sort before unpinned in browse query" {
  # Pin row 4 (dotfiles, low ts)
  bash "${CP_ROOT}/scripts/pin.sh" 4

  first_id="$(query_ids '' | head -1)"
  [ "$first_id" = "4" ]
}

# Case 4: pin survives re-ingest (--force)
@test "preserves pin across re-ingest" {
  bash "${CP_ROOT}/scripts/pin.sh" 1

  # Force full re-ingest
  bash "${CP_ROOT}/scripts/ingest.sh" --force >/dev/null

  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=1;")"
  [ "$pinned" = "1" ]
}

# Case 5: non-existent id is a no-op — exits 0, table unchanged
@test "non-existent id is a no-op" {
  count_before="$(db_query "SELECT count(*) FROM prompts;")"
  pinned_sum_before="$(db_query "SELECT COALESCE(sum(pinned),0) FROM prompts;")"

  run bash "${CP_ROOT}/scripts/pin.sh" 99999
  [ "$status" -eq 0 ]

  count_after="$(db_query "SELECT count(*) FROM prompts;")"
  pinned_sum_after="$(db_query "SELECT COALESCE(sum(pinned),0) FROM prompts;")"

  [ "$count_before" = "$count_after" ]
  [ "$pinned_sum_before" = "$pinned_sum_after" ]
}
