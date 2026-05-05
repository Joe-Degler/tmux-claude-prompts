#!/usr/bin/env bash
# cheatsheet.sh — pretty-printed full keymap for the `?` overlay.
# Reads $CP_RUN_DIR/{similar,group,case} so conditional bindings can be
# re-labeled in active modes.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

ESC=$'\033'
BOLD="${ESC}[1m"
DIM="${ESC}[38;5;244m"
TITLE="${ESC}[1;38;5;81m"
SECTION="${ESC}[1;38;5;214m"
RESET="${ESC}[0m"

# --- Conditional labels ---
similar_label="enter similar mode"
if [ -f "${CP_RUN_DIR}/similar" ]; then
  similar_label="exit similar mode"
fi

group_label="open group picker"
if [ -f "${CP_RUN_DIR}/group" ]; then
  group_label="change or exit current group"
fi

case_label="toggle case sensitivity"
if [ -f "${CP_CASE_FILE:-${CP_RUN_DIR}/case}" ]; then
  cm="$(cat "${CP_CASE_FILE:-${CP_RUN_DIR}/case}" 2>/dev/null || true)"
  if [ "$cm" = "sensitive" ]; then
    case_label="toggle case sensitivity (currently: sensitive)"
  fi
fi

# --- Render ---
printf '\n  %sCLAUDE PROMPTS%s — keymap\n\n' "$TITLE" "$RESET"

printf '  %sOutput%s\n' "$SECTION" "$RESET"
printf '    %sEnter%s        insert resolved prompt into pane\n' "$BOLD" "$RESET"
printf '    %sCtrl-L%s       insert literal (with paste markers)\n' "$BOLD" "$RESET"
printf '    %sCtrl-O%s       copy resolved prompt to clipboard\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sPer-row%s\n' "$SECTION" "$RESET"
printf '    %sCtrl-P%s       toggle pin (star)\n' "$BOLD" "$RESET"
printf '    %sCtrl-G%s       %s\n' "$BOLD" "$RESET" "$group_label"
printf '    %sCtrl-A%s       row actions (group-add · label · delete)\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sSearch modes%s\n' "$SECTION" "$RESET"
printf '    %sCtrl-/%s       %s\n' "$BOLD" "$RESET" "$similar_label"
printf '    %sCtrl-T%s       %s\n' "$BOLD" "$RESET" "$case_label"
printf '    %sCtrl-S%s       toggle scope (everywhere ↔ project)\n' "$BOLD" "$RESET"
printf '    %sShift-←/→%s    cycle scope\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sView%s\n' "$SECTION" "$RESET"
printf '    %s?%s            toggle this cheatsheet (you are here)\n' "$BOLD" "$RESET"
printf '    %sShift-↑/↓%s    scroll preview by line\n' "$BOLD" "$RESET"
printf '    %sAlt-↑/↓%s      scroll preview by half-page\n' "$BOLD" "$RESET"
printf '    %sCtrl-]%s       cycle preview window size (incl. hidden)\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sLifecycle%s\n' "$SECTION" "$RESET"
printf '    %sCtrl-R%s       force re-ingest\n' "$BOLD" "$RESET"
printf '    %sCtrl-Q%s       close popup  (Esc also works but has slight terminal lag)\n' "$BOLD" "$RESET"
printf '    %sAlt-Q%s        close popup (alias for Ctrl-Q)\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sPress ? again to dismiss%s\n' "$DIM" "$RESET"
