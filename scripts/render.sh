#!/usr/bin/env bash
# render.sh — sourced library. Defines cp_render_rows, the formatter shared
# by query.sh (lexical search) and similar.sh (semantic neighbors).
#
# Input on stdin: id<RS>display<RS>project<RS>ts<RS>pinned<RS>label per row, RS=0x1e.
# Output on stdout: id\x1f<ANSI-rendered-line>\n per row (the fzf format).
#
# Honors $CP_SCOPE_FILE to decide whether to render the project chip.

[ "${CP_RENDER_LOADED:-}" = "1" ] && return 0
CP_RENDER_LOADED=1

_render_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_render_dir}/glyphs.sh"
. "${_render_dir}/helpers.sh"

cp_render_rows() {
  local RS=$'\x1e'
  local ESC=$'\033'
  local RESET="${ESC}[0m"

  local ANSI_PIN_ON
  ANSI_PIN_ON="$(printf '%s[38;5;%sm%s%s' "$ESC" "${GLYPH_COLOR[pin_on]}" "${GLYPHS[pin_on]}" "$RESET")"
  local ANSI_HOT
  ANSI_HOT="$(printf '%s[38;5;%sm%s%s' "$ESC" "${GLYPH_COLOR[hot]}" "${GLYPHS[hot]}" "$RESET")"
  local ANSI_WARM
  ANSI_WARM="$(printf '%s[38;5;%sm%s%s' "$ESC" "${GLYPH_COLOR[warm]}" "${GLYPHS[warm]}" "$RESET")"
  local ANSI_PROJ_OPEN
  ANSI_PROJ_OPEN="$(printf '%s[38;5;%sm' "$ESC" "${GLYPH_COLOR[proj]}")"

  local NOW_MS
  NOW_MS="$(now_ms)"
  local ONE_DAY_MS=86400000
  local SEVEN_DAYS_MS=604800000

  local PIN_OFF="${GLYPHS[pin_off]}"
  local COLD="${GLYPHS[cold]}"
  local TRUNC="${GLYPHS[trunc]}"
  local EMPTY_CHIP="                "

  local scope="everywhere"
  if [ -f "$CP_SCOPE_FILE" ]; then
    scope="$(cat "$CP_SCOPE_FILE")"
  fi
  [ -z "$scope" ] && scope="everywhere"
  local SHOW_CHIP=0
  [ "$scope" = "everywhere" ] && SHOW_CHIP=1

  local id display project ts pinned label
  local pin_str rec_str chip_str chip_name disp age_ms label_str

  while IFS="$RS" read -r id display project ts pinned label; do
    [ -z "$id" ] && continue

    if [ "${pinned:-0}" = "1" ]; then
      pin_str="$ANSI_PIN_ON"
    else
      pin_str="$PIN_OFF"
    fi

    age_ms=$(( NOW_MS - ts ))
    if [ "$age_ms" -lt "$ONE_DAY_MS" ]; then
      rec_str="$ANSI_HOT"
    elif [ "$age_ms" -lt "$SEVEN_DAYS_MS" ]; then
      rec_str="$ANSI_WARM"
    else
      rec_str="$COLD"
    fi

    if [ "$SHOW_CHIP" -eq 1 ]; then
      if [ -n "$project" ]; then
        chip_name="${project##*/}"
        if [ "${#chip_name}" -gt 14 ]; then
          chip_name="${chip_name:0:14}"
        else
          chip_name="${chip_name}              "
          chip_name="${chip_name:0:14}"
        fi
        chip_str="${ANSI_PROJ_OPEN}${chip_name}${RESET}  "
      else
        chip_str="$EMPTY_CHIP"
      fi
    else
      chip_str=""
    fi

    label_str=""
    if [ -n "${label:-}" ]; then
      # Defensive: strip embedded ESC sequences and clamp to 60 chars so a
      # malicious / oversized label can't blow up the row.
      label="${label//$'\033'/}"
      if [ "${#label}" -gt 60 ]; then label="${label:0:60}"; fi
      label_str="$(printf '%s[38;5;179m[%s]%s ' "$ESC" "$label" "$RESET")"
    fi

    disp="$display"
    if [ "${#disp}" -gt 500 ]; then
      disp="${disp:0:500}${TRUNC}"
    fi

    printf '%s\x1f%s %s %s%s%s\n' "$id" "$pin_str" "$rec_str" "$chip_str" "$label_str" "$disp"
  done
}
