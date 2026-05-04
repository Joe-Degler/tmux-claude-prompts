#!/usr/bin/env bash
# case.sh — manage the case-sensitivity file.
# Usage:
#   case.sh get              — print current mode (insensitive | sensitive)
#   case.sh set <mode>       — set mode explicitly
#   case.sh toggle           — flip between insensitive and sensitive
# Default (file absent): insensitive.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

mkdir -p "$CP_RUN_DIR"
chmod 0700 "$CP_RUN_DIR"

cmd="${1:-}"

if [ -z "$cmd" ]; then
  printf 'case.sh: usage: case.sh <get|set <mode>|toggle>\n' >&2
  exit 1
fi

read_mode() {
  if [ -f "$CP_CASE_FILE" ]; then
    cat "$CP_CASE_FILE"
  else
    printf 'insensitive'
  fi
}

write_mode() {
  local value="$1"
  local tmp
  tmp="$(mktemp "${CP_RUN_DIR}/case_XXXXXX")"
  printf '%s' "$value" > "$tmp"
  mv "$tmp" "$CP_CASE_FILE"
}

case "$cmd" in
  get)
    read_mode
    printf '\n'
    ;;
  set)
    mode="${2:-}"
    case "$mode" in
      insensitive|sensitive)
        write_mode "$mode"
        ;;
      *)
        printf 'case.sh: mode must be "insensitive" or "sensitive", got: %s\n' "$mode" >&2
        exit 1
        ;;
    esac
    ;;
  toggle)
    current="$(read_mode)"
    if [ "$current" = "sensitive" ]; then
      write_mode "insensitive"
    else
      write_mode "sensitive"
    fi
    ;;
  *)
    printf 'case.sh: unknown command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
