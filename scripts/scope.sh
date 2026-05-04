#!/usr/bin/env bash
# scope.sh — manage the scope file (everywhere ↔ project path).
# Usage:
#   scope.sh get              — print current scope
#   scope.sh set <path>       — set scope to <path> (must be absolute) or "everywhere"
#   scope.sh toggle           — flip between everywhere and $ORIG_PATH/$PWD
#   scope.sh list             — print ordered scope list (one per line)
#   scope.sh next             — cycle to next scope in list (wraps)
#   scope.sh prev             — cycle to previous scope in list (wraps)
# Exit codes: 0 success, 1 invalid usage.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

# Ensure runtime dir exists with correct permissions
mkdir -p "$CP_RUN_DIR"
chmod 0700 "$CP_RUN_DIR"

cmd="${1:-}"

if [ -z "$cmd" ]; then
  printf 'scope.sh: usage: scope.sh <get|set <path>|toggle>\n' >&2
  exit 1
fi

# Read current scope (default: everywhere)
read_scope() {
  if [ -f "$CP_SCOPE_FILE" ]; then
    cat "$CP_SCOPE_FILE"
  else
    printf 'everywhere'
  fi
}

# Atomic write: write to temp then mv
write_scope() {
  local value="$1"
  local tmp
  tmp="$(mktemp "${CP_RUN_DIR}/scope_XXXXXX")"
  printf '%s' "$value" > "$tmp"
  mv "$tmp" "$CP_SCOPE_FILE"
}

case "$cmd" in
  get)
    read_scope
    printf '\n'
    ;;

  set)
    path="${2:-}"
    if [ -z "$path" ]; then
      printf 'scope.sh: set requires a path argument\n' >&2
      exit 1
    fi
    if [ "$path" = "everywhere" ]; then
      write_scope "everywhere"
    else
      # Validate absolute path
      case "$path" in
        /*)  ;;
        *)
          printf 'scope.sh: path must be absolute (or "everywhere"), got: %s\n' "$path" >&2
          exit 1
          ;;
      esac
      write_scope "$path"
    fi
    ;;

  toggle)
    current="$(read_scope)"
    if [ "$current" = "everywhere" ]; then
      # Switch to project scope: use ORIG_PATH env var, fall back to PWD
      target="${ORIG_PATH:-$PWD}"
      write_scope "$target"
    else
      write_scope "everywhere"
    fi
    ;;

  list)
    # Ordered scope list: "everywhere" first, then each distinct project
    # ordered by most-recent prompt timestamp. Used by next/prev cycling
    # and by header.sh to render the chip strip.
    printf 'everywhere\n'
    sqlite3 -cmd ".timeout 3000" "$CP_DB" \
      "SELECT project FROM prompts WHERE project IS NOT NULL AND project <> '' GROUP BY project ORDER BY MAX(ts) DESC;" \
      2>/dev/null || true
    ;;

  next|prev)
    current="$(read_scope)"
    mapfile -t scopes < <("$0" list)
    total=${#scopes[@]}
    if [ "$total" -eq 0 ]; then
      exit 0
    fi
    idx=-1
    for i in "${!scopes[@]}"; do
      if [ "${scopes[$i]}" = "$current" ]; then
        idx="$i"
        break
      fi
    done
    if [ "$idx" -lt 0 ]; then
      idx=0
    elif [ "$cmd" = "next" ]; then
      idx=$(( (idx + 1) % total ))
    else
      idx=$(( (idx - 1 + total) % total ))
    fi
    write_scope "${scopes[$idx]}"
    ;;

  *)
    printf 'scope.sh: unknown command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
