#!/usr/bin/env bats
# tests/query.bats — 8 cases testing query.sh behavior.

load 'helpers.bash'

setup() {
  load_fixtures
  setup_db
}

teardown() {
  teardown_fixtures
}

# Helper: get id of a prompt by its display_full
db_id_for() {
  sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT id FROM prompts WHERE display_full = '$1';"
}

# Case 1: empty query returns recent first
# The /init row deduped to ts=1714780500000 should be first non-pinned row
@test "empty query returns recent first" {
  local init_id
  init_id="$(db_id_for '/init what should the schema look like')"

  # First id emitted by query_ids should be the /init row
  first_id="$(query_ids '' | head -1)"
  [ "$first_id" = "$init_id" ]
}

# Case 2: case-insensitive FTS match — both cloudflare rows
@test "case-insensitive match" {
  count="$(query_ids 'cloudflare' | wc -l | tr -d ' ')"
  [ "$count" -ge 2 ]
}

# Case 3: FTS prefix tokens match cloudflare rows
@test "prefix tokens match" {
  count="$(query_ids 'cloud' | wc -l | tr -d ' ')"
  [ "$count" -ge 2 ]
}

# Case 4: symbol-only query triggers LIKE fallback and finds /init
@test "fallback LIKE engaged for symbol-only query" {
  local init_id
  init_id="$(db_id_for '/init what should the schema look like')"

  ids="$(query_ids '/')"
  # The /init id must appear in results
  [[ "$ids" == *"$init_id"* ]]
}

# Case 5: scope=project filters by project
@test "scope=project filters by project" {
  # Write api-service scope
  printf '%s' '/opt/development/api-service' > "$CP_SCOPE_FILE"

  ids="$(query_ids '')"
  # All returned ids must belong to api-service
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    proj="$(sqlite3 "$CP_DB" "SELECT project FROM prompts WHERE id=${id};")"
    [ "$proj" = "/opt/development/api-service" ]
  done <<< "$ids"

  # And we must have at least 1 result (api-service has rows)
  count="$(printf '%s\n' "$ids" | grep -c '[0-9]' || true)"
  [ "$count" -ge 1 ]
}

# Case 6: pinned rows sort first
@test "pinned rows sort first" {
  # Pin the dotfiles row (low ts = 1714740000000)
  dotfiles_id="$(db_id_for 'Update zsh aliases
Also check brew shellenv
Run shellcheck on .zshrc')"
  bash "${CP_ROOT}/scripts/pin.sh" "$dotfiles_id"

  first_id="$(query_ids '' | head -1)"
  [ "$first_id" = "$dotfiles_id" ]
}

# Case 7: FTS finds prompt by paste content — ENOENT is in paste body of playbook row
@test "FTS finds prompt by paste content" {
  local playbook_id
  playbook_id="$(db_id_for 'Look at this:
[Pasted text #1 +5 lines]
and also [Pasted text #2 +2 lines]')"

  ids="$(query_ids 'ENOENT')"
  [[ "$ids" == *"$playbook_id"* ]]

  # Should be exactly 1 result
  count="$(printf '%s\n' "$ids" | grep -c '[0-9]' || true)"
  [ "$count" -eq 1 ]
}

# Case 8: FTS finds prompt by paste content with prefix — refresh matches refresh_token
@test "FTS finds prompt by paste content with prefix" {
  # The api-service paste-only row contains "def refresh_token():" in paste content
  local paste_only_id
  paste_only_id="$(db_id_for '[Pasted text #1 +3 lines]')"

  ids="$(query_ids 'refresh')"
  [[ "$ids" == *"$paste_only_id"* ]]
}
