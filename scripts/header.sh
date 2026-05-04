#!/usr/bin/env bash
# header.sh — emit fzf --header content (status line + footer hint).
# Output: two lines separated by \n (or one line if narrow).
# Called at launch and on Ctrl-S (scope toggle) via transform-header.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"

require_dep sqlite3

# Detect terminal width: FZF_PREVIEW_COLUMNS, COLUMNS, or default 80
cols="${FZF_PREVIEW_COLUMNS:-${COLUMNS:-80}}"

# --- Read scope ---
scope="everywhere"
if [ -f "$CP_SCOPE_FILE" ]; then
  scope="$(cat "$CP_SCOPE_FILE")"
fi
[ -z "$scope" ] && scope="everywhere"

# --- Read case mode (default: insensitive) ---
case_mode="insensitive"
if [ -f "$CP_CASE_FILE" ]; then
  case_mode="$(cat "$CP_CASE_FILE")"
fi
[ -z "$case_mode" ] && case_mode="insensitive"

if [ "$scope" = "everywhere" ]; then
  proj_filter=""
else
  proj_filter="$scope"
fi

# --- Count prompts in current scope ---
sq_proj="$(sql_quote "$proj_filter")"
count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT count(*) FROM prompts WHERE (${sq_proj} = '' OR project = ${sq_proj});" \
  2>/dev/null || printf '0')"

# --- ANSI helper ---
ansi() {
  local code="$1" text="$2"
  if [ -z "$code" ]; then
    printf '%s' "$text"
  else
    printf '\033[38;5;%sm%s\033[0m' "$code" "$text"
  fi
}

# --- Scope icon and label ---
if [ "$scope" = "everywhere" ]; then
  scope_icon="$(ansi "${GLYPH_COLOR[globe]}" "${GLYPHS[globe]}")"
  scope_label="$(ansi 243 "[Everywhere]")"
else
  scope_icon="$(ansi "${GLYPH_COLOR[proj]}" "${GLYPHS[proj]}")"
  proj_base="$(basename "$scope")"
  scope_label="$(ansi 243 "[${proj_base}]")"
fi

count_str="$(ansi 244 "  ${count}")"

# Case chip: dim when insensitive (default), cyan+bold when sensitive.
if [ "$case_mode" = "sensitive" ]; then
  case_chip="$(printf '\033[1;38;5;81m%s\033[0m' 'Aa')"
else
  case_chip="$(ansi 244 'Aa')"
fi

# Status line (always rendered)
# Format:   Claude Prompts   <scope_icon> <scope_label>   <count>  Aa
status_line="  \033[1mClaude Prompts\033[0m   ${scope_icon} ${scope_label}${count_str}  ${case_chip}"

printf '%b\n' "$status_line"

# Footer hint line (omit if narrow < 70 cols)
if [ "${cols:-80}" -ge 70 ]; then
  # Dim color 244 for the footer
  footer="\033[38;5;244m  enter insert  ^l literal  ^p pin  ^s scope  ^t case  ^o copy  esc close\033[0m"
  printf '%b\n' "$footer"
fi
