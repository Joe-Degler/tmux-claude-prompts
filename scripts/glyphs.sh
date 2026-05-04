#!/usr/bin/env bash
# glyphs.sh — sourced. Defines GLYPHS associative array and GLYPH_COLOR array.
# Selection logic:
#   1. CLAUDE_PROMPTS_NO_NERD=1 env var → ASCII
#   2. @claude_prompts_no_nerd tmux option = "1" (via get_option) → ASCII
#   3. tmux not running and env var unset → Nerd (default)
#   4. Otherwise → Nerd
# GLYPH_COLOR maps key → 256-color code for use in query.sh ANSI sequences.

[ "${CP_GLYPHS_LOADED:-}" = "1" ] && return 0
CP_GLYPHS_LOADED=1

_glyphs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_glyphs_dir}/helpers.sh"

declare -A GLYPHS
declare -A GLYPH_COLOR

_use_ascii=0

# Check env var first (takes priority over tmux option).
if [ "${CLAUDE_PROMPTS_NO_NERD:-}" = "1" ]; then
  _use_ascii=1
elif [ -n "${TMUX:-}" ]; then
  # Only query tmux option when tmux is actually running.
  _no_nerd_opt="$(get_option "@claude_prompts_no_nerd" "")"
  if [ "${_no_nerd_opt}" = "1" ]; then
    _use_ascii=1
  fi
fi
# If tmux is not running and env var is unset → _use_ascii remains 0 → Nerd glyphs.

if [ "$_use_ascii" -eq 1 ]; then
  # ASCII fallback glyphs
  GLYPHS[pin_on]="*"
  GLYPHS[pin_off]=" "
  GLYPHS[hot]="."
  GLYPHS[warm]=","
  GLYPHS[cold]=" "
  GLYPHS[proj]=">"
  GLYPHS[globe]="@"
  GLYPHS[nl]='\n'
  GLYPHS[trunc]="..."
  GLYPHS[ret]=" "
else
  # Nerd Font glyphs (Unicode)
  GLYPHS[pin_on]="★"
  GLYPHS[pin_off]=" "
  GLYPHS[hot]="•"
  GLYPHS[warm]="·"
  GLYPHS[cold]=" "
  GLYPHS[proj]=""
  GLYPHS[globe]=""
  GLYPHS[nl]="↵"
  GLYPHS[trunc]="…"
  GLYPHS[ret]=" "
fi

# 256-color codes per Appendix A of the blueprint.
GLYPH_COLOR[pin_on]=214   # amber
GLYPH_COLOR[pin_off]=""
GLYPH_COLOR[hot]=244
GLYPH_COLOR[warm]=244
GLYPH_COLOR[cold]=""
GLYPH_COLOR[proj]=243
GLYPH_COLOR[globe]=81    # cyan
GLYPH_COLOR[nl]=244
GLYPH_COLOR[trunc]=""
GLYPH_COLOR[ret]=""

unset _use_ascii _no_nerd_opt
