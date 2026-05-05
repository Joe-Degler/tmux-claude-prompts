#!/usr/bin/env bats
# tests/groups.bats — group + label feature tests.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
}

teardown() {
  teardown_fixtures
}

db_query() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" "$1"
}

# Case 1: schema migration ends at user_version 6 with the expected new tables.
@test "schema is at user_version 6 with groups + label" {
  ver="$(db_query 'PRAGMA user_version;')"
  [ "$ver" = "6" ]

  has_groups="$(db_query "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='groups';")"
  [ "$has_groups" = "1" ]

  has_members="$(db_query "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='group_members';")"
  [ "$has_members" = "1" ]

  has_label_col="$(db_query "SELECT count(*) FROM pragma_table_info('prompts') WHERE name='label';")"
  [ "$has_label_col" = "1" ]

  fts_cols="$(db_query "SELECT name FROM pragma_table_info('prompts_fts');" | tr '\n' ' ')"
  [[ "$fts_cols" == *"body"* ]]
  [[ "$fts_cols" == *"label"* ]]
}

# Case 2: setting a label puts the text into the FTS5 'label' column so
# `prompts_fts MATCH 'label:<term>'` returns the row.
@test "label text becomes FTS-searchable via the label column" {
  init_id="$(db_query "SELECT id FROM prompts WHERE display_full = '/init what should the schema look like';")"

  bash "${CP_ROOT}/scripts/label_set.sh" "$init_id" "favourite"

  hits="$(db_query "SELECT rowid FROM prompts_fts WHERE prompts_fts MATCH 'label:favourite';")"
  [ "$hits" = "$init_id" ]
}

# Case 3: with a group active, dispatch.sh narrows the result set to the group's members.
@test "group dispatch narrows to member ids" {
  # Create a group with 2 prompts.
  db_query "INSERT INTO groups(name, ts) VALUES ('NarrowTest', strftime('%s','now')*1000);" >/dev/null
  gid="$(db_query "SELECT id FROM groups WHERE name='NarrowTest';")"
  ids="$(db_query "SELECT id FROM prompts ORDER BY id LIMIT 2;" | tr '\n' ' ')"
  for p in $ids; do
    db_query "INSERT INTO group_members(group_id, prompt_id, ts) VALUES (${gid}, ${p}, strftime('%s','now')*1000);" >/dev/null
  done

  printf '%s' "$gid" > "$CP_RUN_DIR/group"

  rows="$(bash "${CP_ROOT}/scripts/dispatch.sh" '' | awk -F'\x1f' '{print $1}' | tr '\n' ' ')"
  # Result must contain the two member ids and only the two member ids.
  result_count="$(printf '%s\n' "$rows" | tr ' ' '\n' | grep -c '[0-9]' || true)"
  [ "$result_count" = "2" ]
  for p in $ids; do
    [[ "$rows" == *"$p"* ]]
  done

  rm -f "$CP_RUN_DIR/group"
}

# Case 4: adding a row to an active group auto-stars it (pinned=1).
@test "group_add auto-stars a previously-unpinned row" {
  db_query "INSERT INTO groups(name, ts) VALUES ('AutoStarG', strftime('%s','now')*1000);" >/dev/null
  gid="$(db_query "SELECT id FROM groups WHERE name='AutoStarG';")"
  printf '%s' "$gid" > "$CP_RUN_DIR/group"

  pid="$(db_query "SELECT id FROM prompts WHERE pinned=0 ORDER BY id LIMIT 1;")"
  [ -n "$pid" ]

  bash "${CP_ROOT}/scripts/group_add.sh" "$pid"

  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=${pid};")"
  is_member="$(db_query "SELECT count(*) FROM group_members WHERE group_id=${gid} AND prompt_id=${pid};")"
  [ "$pinned" = "1" ]
  [ "$is_member" = "1" ]

  rm -f "$CP_RUN_DIR/group"
}

# Case 5: setting a label auto-stars an unpinned row.
@test "label_set auto-stars a previously-unpinned row" {
  pid="$(db_query "SELECT id FROM prompts WHERE pinned=0 ORDER BY id LIMIT 1;")"
  [ -n "$pid" ]

  bash "${CP_ROOT}/scripts/label_set.sh" "$pid" "tag"

  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=${pid};")"
  label="$(db_query "SELECT label FROM prompts WHERE id=${pid};")"
  [ "$pinned" = "1" ]
  [ "$label" = "tag" ]
}

# Case 6: labels longer than 60 chars are clamped to exactly 60.
@test "label is clamped to 60 chars" {
  pid="$(db_query "SELECT id FROM prompts ORDER BY id LIMIT 1;")"
  long="$(printf 'A%.0s' {1..120})"

  bash "${CP_ROOT}/scripts/label_set.sh" "$pid" "$long"

  label="$(db_query "SELECT label FROM prompts WHERE id=${pid};")"
  [ "${#label}" -eq 60 ]
}

# Case 7: group names collide case-insensitively (NOCASE UNIQUE).
@test "group names are NOCASE unique" {
  bash "${CP_ROOT}/bin/claude-prompts" group create "MyBundle" >/dev/null
  bash "${CP_ROOT}/bin/claude-prompts" group create "mybundle" >/dev/null

  count="$(db_query "SELECT count(*) FROM groups WHERE name COLLATE NOCASE = 'mybundle';")"
  [ "$count" = "1" ]
}

# Case 8: an empty group can exist without crashing the dispatch path.
@test "empty group dispatches to no rows without error" {
  db_query "INSERT INTO groups(name, ts) VALUES ('EmptyG', strftime('%s','now')*1000);" >/dev/null
  gid="$(db_query "SELECT id FROM groups WHERE name='EmptyG';")"
  printf '%s' "$gid" > "$CP_RUN_DIR/group"

  run bash "${CP_ROOT}/scripts/dispatch.sh" ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -f "$CP_RUN_DIR/group"
}

# Case 9: a stale group_file (pointing at a deleted group) is cleaned up by group_add.
@test "stale group_file is removed by group_add" {
  printf '%s' '99999' > "$CP_RUN_DIR/group"

  pid="$(db_query "SELECT id FROM prompts ORDER BY id LIMIT 1;")"
  run bash "${CP_ROOT}/scripts/group_add.sh" "$pid"
  [ "$status" -eq 0 ]

  [ ! -f "$CP_RUN_DIR/group" ]
}

# Case 10: deleting a group cascades to group_members (FK pragma must be on).
@test "group delete cascades to group_members" {
  gid="$(db_query "INSERT INTO groups(name, ts) VALUES ('CascadeTest', 1000); SELECT last_insert_rowid();")"
  pid="$(db_query "SELECT id FROM prompts ORDER BY id LIMIT 1;")"
  db_query "INSERT INTO group_members(group_id, prompt_id, ts) VALUES (${gid}, ${pid}, 1000);"
  bash "${CP_ROOT}/bin/claude-prompts" group delete "$gid"
  count="$(db_query "SELECT count(*) FROM group_members WHERE group_id=${gid};")"
  [ "$count" = "0" ]
}

# Case 11: toggling a row out of a group must NOT unstar it (auto-star is sticky).
@test "group_add toggle-off removes member without unstarring" {
  db_query "INSERT INTO groups(name, ts) VALUES ('ToggleG', 1000);"
  gid="$(db_query "SELECT id FROM groups WHERE name='ToggleG';")"
  printf '%s' "$gid" > "$CP_RUN_DIR/group"
  pid="$(db_query "SELECT id FROM prompts ORDER BY id LIMIT 1;")"
  bash "${CP_ROOT}/scripts/group_add.sh" "$pid"   # add → also stars
  bash "${CP_ROOT}/scripts/group_add.sh" "$pid"   # toggle off
  count="$(db_query "SELECT count(*) FROM group_members WHERE group_id=${gid} AND prompt_id=${pid};")"
  pinned="$(db_query "SELECT pinned FROM prompts WHERE id=${pid};")"
  [ "$count" = "0" ]
  [ "$pinned" = "1" ]   # auto-star is sticky — DELETE must NOT unpin
  rm -f "$CP_RUN_DIR/group"
}

# Case 12: action palette dispatches the `delete` verb to delete.sh.
@test "action palette dispatches delete to delete.sh" {
  pid="$(db_query 'SELECT id FROM prompts ORDER BY id LIMIT 1;')"
  bash "${CP_ROOT}/scripts/action_palette.sh" "$pid" delete
  [ "$(db_query "SELECT count(*) FROM prompts WHERE id=${pid};")" = "0" ]
}

# --- Cheatsheet overlay tests ---

@test "cheatsheet renders non-empty output" {
  run bash "${CP_ROOT}/scripts/cheatsheet.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Output"* ]]
  [[ "$output" == *"Per-row"* ]]
  [[ "$output" == *"Search modes"* ]]
}

@test "cheatsheet relabels Ctrl-/ when similar mode active" {
  printf '42' > "$CP_RUN_DIR/similar"
  run bash "${CP_ROOT}/scripts/cheatsheet.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit similar"* ]]
  rm -f "$CP_RUN_DIR/similar"
}

@test "cheatsheet relabels Ctrl-G when group mode active" {
  printf '1' > "$CP_RUN_DIR/group"
  run bash "${CP_ROOT}/scripts/cheatsheet.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit"* ]] || [[ "$output" == *"change"* ]]
  rm -f "$CP_RUN_DIR/group"
}

@test "cheatsheet_toggle creates and removes the state file" {
  rm -f "$CP_RUN_DIR/cheatsheet"
  bash "${CP_ROOT}/scripts/cheatsheet_toggle.sh"
  [ -f "$CP_RUN_DIR/cheatsheet" ]
  bash "${CP_ROOT}/scripts/cheatsheet_toggle.sh"
  [ ! -f "$CP_RUN_DIR/cheatsheet" ]
}

# group_pick.sh --exit clears group mode without creating any synthetic group.
@test "group_pick exit-sentinel clears group mode" {
  db_query "INSERT INTO groups(name, ts) VALUES ('ExitTestGroup', 1000);"
  gid="$(db_query "SELECT id FROM groups WHERE name='ExitTestGroup';")"
  printf '%s' "$gid" > "$CP_RUN_DIR/group"
  [ -f "$CP_RUN_DIR/group" ]

  bash "${CP_ROOT}/scripts/group_pick.sh" --exit

  [ ! -f "$CP_RUN_DIR/group" ]
  # Sanity: --exit must NOT have invented a synthetic group with id=0 etc.
  count="$(db_query "SELECT count(*) FROM groups;")"
  [ "$count" = "1" ]
}
