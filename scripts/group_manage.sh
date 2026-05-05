#!/usr/bin/env bash
# group_manage.sh — CLI for `claude-prompts group <subcmd>`.
# Subcommands:
#   list                        Print "<id>\t<name>\t<member_count>" per group
#   create <name>               Create a group; print "<id>\t<name>"
#   delete <id>                 Delete a group (cascades members)
#   rename <id> <new_name>      Rename a group

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3
ensure_db

usage() {
  cat >&2 <<'EOF'
Usage: claude-prompts group <list|create|delete|rename> [args...]
  list                        List all groups (id, name, member count)
  create <name>               Create a new group
  delete <id>                 Delete a group
  rename <id> <new_name>      Rename a group
EOF
}

sub="${1:-}"
shift || true

case "$sub" in
  list)
    sqlite3 -separator $'\t' -cmd ".timeout 3000" "$CP_DB" \
      "SELECT g.id, g.name, (SELECT count(*) FROM group_members WHERE group_id=g.id) FROM groups g ORDER BY g.ts DESC;"
    ;;

  create)
    name="${1:-}"
    if [ -z "$name" ]; then
      printf 'group create: missing <name>\n' >&2
      usage; exit 1
    fi
    sq_name="$(sql_quote "$name")"
    NOW="$(now_ms)"
    sqlite3 -bail "$CP_DB" >/dev/null <<SQL
INSERT OR IGNORE INTO groups(name, ts) VALUES (${sq_name}, ${NOW});
SQL
    sqlite3 -separator $'\t' -cmd ".timeout 3000" "$CP_DB" \
      "SELECT id, name FROM groups WHERE name=${sq_name} COLLATE NOCASE;"
    ;;

  delete)
    gid="${1:-}"
    if [ -z "$gid" ] || ! printf '%s' "$gid" | grep -qE '^[0-9]+$'; then
      printf 'group delete: invalid <id>: %s\n' "$gid" >&2
      usage; exit 1
    fi
    sq_gid="$(sql_quote "$gid")"
    sqlite3 -bail -cmd ".timeout 3000" -cmd "PRAGMA foreign_keys=ON;" "$CP_DB" >/dev/null \
      "DELETE FROM groups WHERE id=${sq_gid};"
    ;;

  rename)
    gid="${1:-}"
    new_name="${2:-}"
    if [ -z "$gid" ] || ! printf '%s' "$gid" | grep -qE '^[0-9]+$' || [ -z "$new_name" ]; then
      printf 'group rename: usage: rename <id> <new_name>\n' >&2
      usage; exit 1
    fi
    sq_gid="$(sql_quote "$gid")"
    sq_name="$(sql_quote "$new_name")"
    sqlite3 -bail "$CP_DB" >/dev/null \
      "UPDATE groups SET name=${sq_name} WHERE id=${sq_gid};"
    ;;

  ""|help|-h|--help)
    usage
    [ -z "$sub" ] && exit 1 || exit 0
    ;;

  *)
    printf 'group: unknown subcommand: %s\n' "$sub" >&2
    usage
    exit 1
    ;;
esac
