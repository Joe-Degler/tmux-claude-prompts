#!/usr/bin/env bash
# header.sh — emit fzf --header content.
# Output:
#   - Always: title line, footer hint
#   - When scoped to a project: scope chip strip between them
# Called at launch and via transform-header on scope/case/refresh actions.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"

require_dep sqlite3

# Detect width: fzf sets FZF_COLUMNS during action commands; otherwise
# fall back to COLUMNS (set by the parent shell / popup) or 80.
# Important: do NOT use FZF_PREVIEW_COLUMNS — that's the preview pane width,
# not the header width, and it makes the chip strip shrink during cycling.
cols="${FZF_COLUMNS:-${COLUMNS:-80}}"

# --- Read scope ---
scope="everywhere"
if [ -f "$CP_SCOPE_FILE" ]; then
  scope="$(cat "$CP_SCOPE_FILE")"
fi
[ -z "$scope" ] && scope="everywhere"

if [ "$scope" = "everywhere" ]; then
  proj_filter=""
else
  proj_filter="$scope"
fi

# --- Session mode? Row counts and title adapt. ---
session_mode=0
[ -f "${CP_RUN_DIR}/sessions" ] && session_mode=1

# --- Count rows in current scope ---
sq_proj="$(sql_quote "$proj_filter")"
if [ "$session_mode" -eq 1 ]; then
  count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT count(*) FROM sessions WHERE (${sq_proj} = '' OR project = ${sq_proj});" \
    2>/dev/null || printf '0')"
else
  count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT count(*) FROM prompts WHERE (${sq_proj} = '' OR project = ${sq_proj});" \
    2>/dev/null || printf '0')"
fi

# --- ANSI helper ---
ansi() {
  local code="$1" text="$2"
  if [ -z "$code" ]; then
    printf '%s' "$text"
  else
    printf '\033[38;5;%sm%s\033[0m' "$code" "$text"
  fi
}

count_str="$(ansi 244 "  ${count}")"

# --- Title line ---
# In Everywhere mode, show the [Everywhere] label inline (no chip strip below).
# In project mode, omit the label — the chip strip below shows the active scope.
title_text="Claude Prompts"
indexing_str=""
if [ "$session_mode" -eq 1 ]; then
  title_text="Claude Sessions"
  if [ "$(cat "${CP_RUN_DIR}/session_ingest_status" 2>/dev/null || true)" = "running" ]; then
    indexing_str="$(ansi 244 "  indexing${GLYPHS[trunc]}")"
  fi
fi
if [ "$scope" = "everywhere" ]; then
  scope_icon="$(ansi "${GLYPH_COLOR[globe]}" "${GLYPHS[globe]}")"
  scope_label="$(ansi 243 "[Everywhere]")"
  title_line="  \033[1m${title_text}\033[0m   ${scope_icon} ${scope_label}${count_str}${indexing_str}"
else
  title_line="  \033[1m${title_text}\033[0m${count_str}${indexing_str}"
fi
printf '%b\n' "$title_line"

# --- Group-mode banner (only when $CP_RUN_DIR/group holds a group id) ---
if [ -f "${CP_RUN_DIR}/group" ]; then
  grp_id="$(< "${CP_RUN_DIR}/group")"
  if [ -n "$grp_id" ]; then
    sq_gid="$(sql_quote "$grp_id")"
    grp_name="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
      "SELECT name FROM groups WHERE id=${sq_gid};" 2>/dev/null || true)"
    grp_count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
      "SELECT count(*) FROM group_members WHERE group_id=${sq_gid};" 2>/dev/null || printf '0')"
    if [ -n "$grp_name" ]; then
      max_len=$(( cols - 20 ))
      [ "$max_len" -lt 10 ] && max_len=10
      if [ "${#grp_name}" -gt "$max_len" ]; then
        grp_name="${grp_name:0:$max_len}${GLYPHS[trunc]}"
      fi
      printf '%b\n' "$(printf '\033[1;38;5;214m  # Group:\033[0m %s \033[38;5;244m(%s prompts)\033[0m' "$grp_name" "$grp_count")"
    fi
  fi
fi

# --- Similar-mode banner (only when $CP_RUN_DIR/similar holds a source id) ---
if [ -f "${CP_RUN_DIR}/similar" ]; then
  src_id="$(cat "${CP_RUN_DIR}/similar" 2>/dev/null || true)"
  if [ -n "$src_id" ]; then
    sq_id="$(sql_quote "$src_id")"
    src_preview="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
      "SELECT COALESCE(NULLIF(display_preview, ''), display) FROM prompts WHERE id = ${sq_id};" \
      2>/dev/null || true)"
    if [ -n "$src_preview" ]; then
      # Truncate to ~ (cols - 18) so it fits next to the "~ Similar to: " label.
      max_len=$(( cols - 18 ))
      [ "$max_len" -lt 20 ] && max_len=20
      if [ "${#src_preview}" -gt "$max_len" ]; then
        src_preview="${src_preview:0:$max_len}${GLYPHS[trunc]}"
      fi
      banner="$(printf '\033[1;38;5;81m  ~ Similar to:\033[0m %s' "$src_preview")"
      printf '%b\n' "$banner"
    fi
  fi
fi

# --- Scope chip strip (only when in project scope) ---
if [ "$scope" != "everywhere" ]; then
  mapfile -t scopes < <("${SCRIPT_DIR}/scope.sh" list)
  total=${#scopes[@]}

  if [ "$total" -gt 0 ]; then
    cur_idx=0
    for i in "${!scopes[@]}"; do
      if [ "${scopes[$i]}" = "$scope" ]; then
        cur_idx=$i
        break
      fi
    done

    scope_label_for() {
      if [ "$1" = "everywhere" ]; then
        printf 'Everywhere'
      else
        local base="${1##*/}"
        if [ "${#base}" -gt 18 ]; then
          base="${base:0:17}${GLYPHS[trunc]}"
        fi
        printf '%s' "$base"
      fi
    }

    declare -a labels
    for s in "${scopes[@]}"; do
      labels+=("$(scope_label_for "$s")")
    done

    # Budget: terminal width minus 4 for padding/markers.
    budget=$(( cols - 4 ))
    [ "$budget" -lt 20 ] && budget=20

    # Each chip is rendered as label plus a 2-space gap. The active chip is
    # also wrapped in "[ ]" (+2 chars). Width is the chip plus its trailing gap.
    chip_width() {
      local i="$1" w
      w=${#labels[$i]}
      if [ "$i" -eq "$cur_idx" ]; then
        w=$((w + 2))
      fi
      printf '%s' "$((w + 2))"
    }

    # Greedy windowing: include current, then alternate-expand left/right
    # so the active chip stays roughly centered.
    start=$cur_idx
    end=$cur_idx
    used="$(chip_width "$cur_idx")"
    expand_left=1
    expand_right=1
    while [ "$expand_left" -eq 1 ] || [ "$expand_right" -eq 1 ]; do
      if [ "$expand_right" -eq 1 ]; then
        if [ "$end" -lt "$((total - 1))" ]; then
          next_w="$(chip_width "$((end + 1))")"
          if [ "$((used + next_w))" -le "$budget" ]; then
            end=$((end + 1))
            used=$((used + next_w))
          else
            expand_right=0
          fi
        else
          expand_right=0
        fi
      fi
      if [ "$expand_left" -eq 1 ]; then
        if [ "$start" -gt 0 ]; then
          prev_w="$(chip_width "$((start - 1))")"
          if [ "$((used + prev_w))" -le "$budget" ]; then
            start=$((start - 1))
            used=$((used + prev_w))
          else
            expand_left=0
          fi
        else
          expand_left=0
        fi
      fi
    done

    strip="  "
    if [ "$start" -gt 0 ]; then
      strip="${strip}$(ansi 244 '‹')  "
    fi
    for i in $(seq "$start" "$end"); do
      label="${labels[$i]}"
      if [ "$i" -eq "$cur_idx" ]; then
        chip="$(printf '\033[1;38;5;81m[%s]\033[0m' "$label")"
      else
        chip="$(ansi 244 "$label")"
      fi
      strip="${strip}${chip}  "
    done
    if [ "$end" -lt "$((total - 1))" ]; then
      strip="${strip}$(ansi 244 '›')"
    fi
    printf '%b\n' "$strip"
  fi
fi

# --- Footer hint line (omit if narrow < 71 cols — full footer width) ---
# Only the most-used keys are always visible; `?` toggles a full cheatsheet
# overlay in the preview pane (see scripts/cheatsheet.sh).
if [ "${cols:-80}" -ge 71 ]; then
  if [ "$session_mode" -eq 1 ]; then
    footer="\033[38;5;244m  enter type /resume  ^o copy /resume  ^e back to prompts  ?  full keymap\033[0m"
  else
    footer="\033[38;5;244m  enter insert  ^l literal  ^o copy  ^p pin  ^a actions  ?  full keymap\033[0m"
  fi
  printf '%b\n' "$footer"
fi
