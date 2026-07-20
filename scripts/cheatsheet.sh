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

session_mode=0
[ -f "${CP_RUN_DIR}/sessions" ] && session_mode=1
sessions_label="enter session-search mode (transcripts incl. Claude)"
enter_label="insert resolved prompt into pane"
ctrl_l_label="insert literal (with paste markers)"
ctrl_o_label="copy resolved prompt to clipboard"
if [ "$session_mode" -eq 1 ]; then
  sessions_label="back to prompt mode"
  enter_label="type /resume <session-id> into pane (does not run it)"
  ctrl_l_label="same as Enter in session mode"
  ctrl_o_label="copy /resume <session-id> to clipboard"
fi

# --- Render ---
printf '\n  %sCLAUDE PROMPTS%s — keymap\n\n' "$TITLE" "$RESET"

printf '  %sOutput%s\n' "$SECTION" "$RESET"
printf '    %sEnter%s        %s\n' "$BOLD" "$RESET" "$enter_label"
printf '    %sCtrl-L%s       %s\n' "$BOLD" "$RESET" "$ctrl_l_label"
printf '    %sCtrl-O%s       %s\n' "$BOLD" "$RESET" "$ctrl_o_label"
printf '\n'

printf '  %sPer-row%s\n' "$SECTION" "$RESET"
printf '    %sCtrl-P%s       toggle pin (star)\n' "$BOLD" "$RESET"
printf '    %sCtrl-G%s       %s\n' "$BOLD" "$RESET" "$group_label"
printf '    %sCtrl-A%s       row actions (group-add · label · delete)\n' "$BOLD" "$RESET"
printf '\n'

printf '  %sSearch modes%s\n' "$SECTION" "$RESET"
printf '    %sCtrl-E%s       %s\n' "$BOLD" "$RESET" "$sessions_label"
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
