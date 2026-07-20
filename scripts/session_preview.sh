#!/usr/bin/env bash
# session_preview.sh — render a session transcript for the preview pane.
# Usage: session_preview.sh <sid> [<query>]
#
# Claude-Code-ish rendering: "> " user turns (cyan), "! " bash inputs
# (yellow), plain assistant text, dim tool one-liners. The preview window is
# opened with `follow` in session mode, so the view starts at the END of the
# transcript ("where we stopped"); Shift-Up scrolls back.
#
# Output is capped (message count + line budget) so huge sessions can't stall
# the per-keystroke preview refresh. Query tokens are highlighted literally
# (no regex interpretation), case-insensitively.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

sid="${1:-}"
query="${2:-}"

# fzf re-runs the preview on {q} changes even with no selected row.
if [ -z "$sid" ] || ! printf '%s' "$sid" | grep -qE '^[0-9a-fA-F-]{8,}$'; then
  printf '(no session selected)\n'
  exit 0
fi

MAX_MSGS=400
MAX_LINES=4000

ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[38;5;244m"
CYAN="${ESC}[1;38;5;81m"
YELLOW="${ESC}[38;5;179m"

sq_sid="$(sql_quote "$sid")"

RS=$'\x1e'
meta="$(sqlite3 -bail -separator "$RS" -cmd ".timeout 3000" "$CP_DB" \
  "SELECT id, project, first_ts, last_ts, msg_count, title FROM sessions WHERE sid = ${sq_sid};" \
  2>/dev/null || true)"
if [ -z "$meta" ]; then
  printf '(session not found — try Ctrl-R to re-ingest)\n'
  exit 0
fi
IFS="$RS" read -r rowid project first_ts last_ts msg_count title <<< "$meta"

fmt_day() {
  local ms="$1"
  [ "${ms:-0}" -eq 0 ] && { printf '?'; return; }
  date -d "@$(( ms / 1000 ))" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?'
}

# --- Header block ---
cols="${FZF_PREVIEW_COLUMNS:-80}"
if [ "${GLYPHS[trunc]}" = "..." ]; then
  FENCE_CHAR="-"; ARROW="->"
else
  FENCE_CHAR="─"; ARROW="→"
fi
FENCE=""
for (( i=0; i<cols; i++ )); do FENCE="${FENCE}${FENCE_CHAR}"; done

printf '%s%s%s\n' "$BOLD" "${title:-(untitled session)}" "$RESET"
printf '%s%s %s %s %s %s %s %s msgs%s\n' \
  "$DIM" "$project" "${GLYPHS[warm]}" "$(fmt_day "$first_ts")" "$ARROW" "$(fmt_day "$last_ts")" "${GLYPHS[warm]}" "$msg_count" "$RESET"
printf '%s/resume %s%s\n' "$DIM" "$sid" "$RESET"
printf '%s\n' "$FENCE"

if [ "${msg_count:-0}" -gt "$MAX_MSGS" ]; then
  printf '%s%s %d earlier messages elided %s%s\n\n' \
    "$DIM" "${GLYPHS[trunc]}" "$(( msg_count - MAX_MSGS ))" "${GLYPHS[trunc]}" "$RESET"
fi

# --- Body ---
# Tail window: last MAX_MSGS messages in chronological order. Unit separator
# 0x1f terminates each row (text can contain newlines but never 0x1f/0x1e —
# stripped at ingest).
sqlite3 -bail -newline $'\x1f' -separator "$RS" -cmd ".timeout 3000" "$CP_DB" \
  "SELECT role, text FROM (
     SELECT seq, role, text FROM session_messages
     WHERE session_id = ${rowid} ORDER BY seq DESC LIMIT ${MAX_MSGS}
   ) ORDER BY seq;" 2>/dev/null |
"$AWK" -v max_lines="$MAX_LINES" -v query="$query" \
  -v c_reset="$RESET" -v c_dim="$DIM" -v c_cyan="$CYAN" -v c_yellow="$YELLOW" '
BEGIN {
  RS = "\x1f"; FS = "\x1e"
  nq = 0
  # Literal, case-insensitive highlighting: split query into tokens, match
  # via index() on a lowercased copy (no regex metacharacter interpretation).
  n = split(tolower(query), raw, /[ \t]+/)
  for (i = 1; i <= n; i++) if (raw[i] != "") tokens[++nq] = raw[i]
  hl_open = "\033[7m"; hl_close = "\033[27m"
  emitted = 0
}
function highlight(line,    low, out, i, best, bestlen, pos) {
  if (nq == 0) return line
  out = ""
  while (1) {
    low = tolower(line); best = 0; bestlen = 0
    for (i = 1; i <= nq; i++) {
      pos = index(low, tokens[i])
      if (pos > 0 && (best == 0 || pos < best)) { best = pos; bestlen = length(tokens[i]) }
    }
    if (best == 0) break
    out = out substr(line, 1, best - 1) hl_open substr(line, best, bestlen) hl_close
    line = substr(line, best + bestlen)
  }
  return out line
}
function emit(line) {
  if (emitted >= max_lines) { if (emitted == max_lines) { print c_dim "... output truncated ..." c_reset; emitted++ }; return }
  print line
  emitted++
}
{
  role = $1
  text = substr($0, index($0, FS) + 1)
  if (role == "" || text == "") next
  n_lines = split(text, lines, "\n")
  if (role == "tool") {
    emit(c_dim "  * " lines[1] c_reset)
    next
  }
  for (i = 1; i <= n_lines; i++) {
    line = highlight(lines[i])
    if (role == "user") {
      prefix = (i == 1 ? c_cyan "> " c_reset : "  ")
      emit(prefix line)
    } else if (role == "bash") {
      prefix = (i == 1 ? c_yellow "! " c_reset : "  ")
      emit(prefix line)
    } else {
      emit(line)
    }
  }
  emit("")
}
'
