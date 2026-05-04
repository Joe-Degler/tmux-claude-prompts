#!/usr/bin/env bash
# prompt.sh — emit fzf --prompt content (Aa case chip + arrow/spaces).
# Used at startup and via fzf's transform-prompt action when Ctrl-T toggles
# case sensitivity, so the chip is always rendered immediately to the left
# of the query input.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"

case_mode="insensitive"
if [ -f "$CP_CASE_FILE" ]; then
  case_mode="$(cat "$CP_CASE_FILE")"
fi
[ -z "$case_mode" ] && case_mode="insensitive"

if [ "$case_mode" = "sensitive" ]; then
  case_chip=$'\033[1;38;5;81mAa\033[0m'
else
  case_chip=$'\033[38;5;244mAa\033[0m'
fi

# In similar mode, prepend a tilde glyph so the prompt visibly indicates
# semantic-search instead of lexical search.
similar_glyph=""
if [ -f "${CP_RUN_DIR}/similar" ]; then
  similar_glyph=$'\033[1;38;5;81m~\033[0m '
fi

# Match the query-pointer style used by popup.sh.
if [ "${GLYPHS[proj]}" = ">" ]; then
  printf '%s %s> ' "$case_chip" "$similar_glyph"
else
  printf '%s %s ' "$case_chip" "$similar_glyph"
fi
