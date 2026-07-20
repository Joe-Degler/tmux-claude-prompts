#!/usr/bin/env bash
# insert.sh — paste or copy a prompt by id.
# Usage: insert.sh <paste|paste-literal|copy> <id>
# Env:   ORIG_PANE  (tmux pane target for paste actions)
#        TMUX       (set by tmux; detects tmux session)
#        CP_DB      (overridable for tests)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

action="${1:-}"
id="${2:-}"

# --- Validate action ---
case "$action" in
  paste|paste-literal|copy) ;;
  *)
    printf 'insert.sh: invalid action: %s (expected paste, paste-literal, or copy)\n' "$action" >&2
    exit 1
    ;;
esac

# --- Session mode: the payload is the /resume command, for every action. ---
# Must run before numeric validation — session ids are uuids.
unmatched_markers=0
if [ -f "${CP_RUN_DIR}/sessions" ]; then
  if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9a-fA-F-]{8,}$'; then
    printf 'insert.sh: invalid session id: %s\n' "$id" >&2
    exit 1
  fi
  text="/resume ${id}"
else

# --- Validate id ---
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'insert.sh: invalid id: %s\n' "$id" >&2
  exit 1
fi

ensure_db

# --- Fetch text ---
if [ "$action" = "paste-literal" ]; then
  text="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT display_full FROM prompts WHERE id=${id};" 2>/dev/null)"
else
  # Resolve paste markers. Exit code 2 → at least one marker had no stored content.
  text="$("${SCRIPT_DIR}/resolve.sh" "$id")" || {
    rc=$?
    [ "$rc" -eq 2 ] && unmatched_markers=1 || exit "$rc"
  }
fi

fi # end prompt-mode branch

# --- Paste into tmux pane ---
do_clipboard=0
if [ "$action" = "paste" ] || [ "$action" = "paste-literal" ]; then
  if [ -n "${TMUX:-}" ] && [ -n "${ORIG_PANE:-}" ]; then
    # Send the text so Claude's TUI sees typed input (not a paste).
    # The heuristic that flips Claude into "[Pasted text]" mode is
    # roughly "a single pty read() returned bytes containing a newline
    # mid-stream". So we just split on \n: send each line as one write,
    # send each newline as its own write. No size threshold matters as
    # long as no chunk mixes text and \n.
    remaining="$text"
    while [[ "$remaining" == *$'\n'* ]]; do
      line="${remaining%%$'\n'*}"
      [ -n "$line" ] && tmux send-keys -t "$ORIG_PANE" -l -- "$line"
      tmux send-keys -t "$ORIG_PANE" -l -- $'\n'
      remaining="${remaining#*$'\n'}"
    done
    [ -n "$remaining" ] && tmux send-keys -t "$ORIG_PANE" -l -- "$remaining"
    if [ "$action" = "paste" ] && [ "$unmatched_markers" -eq 1 ]; then
      tmux display-message -d 3000 -t "$ORIG_PANE" \
        'claude-prompts: paste markers had no stored content — inserted as-is' 2>/dev/null || true
    fi
  else
    printf 'insert.sh: no tmux pane — copied to clipboard instead\n' >&2
    do_clipboard=1
  fi
elif [ "$action" = "copy" ]; then
  do_clipboard=1
fi

# --- Clipboard ---
if [ "$do_clipboard" -eq 1 ]; then
  # WSL detection: clip.exe
  if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$text" | clip.exe
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$text" | xsel --clipboard --input
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy
  else
    printf 'insert.sh: no clipboard tool available (clip.exe, wl-copy, xclip, xsel, pbcopy)\n' >&2
    exit 1
  fi
fi

exit 0
