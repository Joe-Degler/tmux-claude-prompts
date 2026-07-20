#!/usr/bin/env bash
# popup.sh — fzf loop driver; runs INSIDE the tmux popup.
# Env: ORIG_PANE, ORIG_PATH, CP_ROOT (all set by launch.sh via display-popup -e).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"
. "${SCRIPT_DIR}/glyphs.sh"

# Export script path for child binds
export CP_SCRIPTS="$SCRIPT_DIR"

# --- Dependency checks ---
require_dep sqlite3
require_dep fzf
require_dep jq
# Prefer gawk (needed by preview.sh); fall back to awk
if command -v gawk >/dev/null 2>&1; then
  export AWK=gawk
else
  require_dep awk
  export AWK=awk
fi

# --- Ensure DB and apply schema ---
ensure_db

# --- Pick a free port for fzf --listen ---
# When ingest finishes in the background it pings fzf on this port to reload
# the result list. Pre-picking the port (vs. letting fzf bind 0) is the only
# way the BG process can know where to send the notification before fzf has
# started. There's a tiny TOCTOU window where another process could grab the
# port; if that happens the notification silently fails and the user falls
# back to keystroke-driven reload (or Ctrl-R for explicit re-ingest).
CP_FZF_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"

# --- Incremental ingest ---
# Each new history record costs ~150ms (bash loop + jq subprocess thrashing),
# so a backlog of accumulated rows can block popup open for many seconds.
# Run ingest in the background so fzf opens immediately with whatever is
# already in the DB. When ingest finishes, ping fzf via --listen to refresh
# the visible rows. On a near-empty DB (first launch) we block on ingest so
# the initial view isn't an empty list.
prompt_count="$(sqlite3 "$CP_DB" 'SELECT count(*) FROM prompts;' 2>/dev/null || printf '0')"

# nudge_fzf <body> — best-effort action ping to the fzf listener. fzf may not
# be listening yet (or at all if the port pick failed), so retry briefly and
# silently give up.
nudge_fzf() {
  local body="$1"
  [ -z "${CP_FZF_PORT:-}" ] && return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if exec 9<>/dev/tcp/127.0.0.1/${CP_FZF_PORT} 2>/dev/null; then
      printf 'POST / HTTP/1.0\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" >&9 2>/dev/null || true
      exec 9<&- 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
}

if [ "${prompt_count:-0}" -lt 50 ]; then
  "${CP_SCRIPTS}/ingest.sh" >&2 || true
else
  (
    "${CP_SCRIPTS}/ingest.sh" >>"${CP_RUN_DIR}/ingest.log" 2>&1 || true
    nudge_fzf "reload(${CP_SCRIPTS}/dispatch.sh {q})"
  ) </dev/null >/dev/null 2>&1 &
fi

# Session-transcript ingest is its own always-background job: it must not
# block popup open (first sweep reads every transcript) and must not delay
# the prompt-ingest nudge above. Its own nudge also refreshes the header so
# the session count / "indexing" hint update.
(
  CP_DB="$CP_DB" CP_RUN_DIR="$CP_RUN_DIR" \
    python3 "${CP_SCRIPTS}/ingest_sessions.py" >>"${CP_RUN_DIR}/session_ingest.log" 2>&1 || true
  nudge_fzf "reload(${CP_SCRIPTS}/dispatch.sh {q})+transform-header(${CP_SCRIPTS}/header.sh)"
) </dev/null >/dev/null 2>&1 &

# --- Kick off embedding daemon + async backfill in the background. ---
# This never blocks popup open. On first run, the daemon spawn / pip install /
# model download happen out-of-band; lexical search keeps working until the
# daemon is ready, then hybrid + similarity quietly come online.
if [ "${CP_SKIP_EMBED:-0}" != "1" ]; then
  ( "${CP_SCRIPTS}/embed.sh" kickoff >>"${CP_RUN_DIR}/embed_kickoff.log" 2>&1 & ) </dev/null >/dev/null 2>&1
fi

# --- Clear any stale similar-mode state from a previous popup session ---
rm -f "${CP_RUN_DIR}/similar"
rm -f "${CP_RUN_DIR}/group"
rm -f "${CP_RUN_DIR}/cheatsheet"
rm -f "${CP_RUN_DIR}/sessions"

# --- Initial prompt and header (computed once; refreshed by transform-* binds) ---
INITIAL_PROMPT="$("${CP_SCRIPTS}/prompt.sh")"
INITIAL_HEADER="$("${CP_SCRIPTS}/header.sh")"

# --- fzf invocation (exec so this bash process is replaced) ---
# --listen lets the background ingest job ping us with a `reload` action
# once the new history rows hit the DB. If port-pick failed earlier the
# flag is omitted (no listener, nothing to ping).
listen_flag=()
if [ -n "${CP_FZF_PORT:-}" ]; then
  listen_flag=(--listen "$CP_FZF_PORT")
fi

exec fzf \
  "${listen_flag[@]}" \
  --disabled \
  --ansi \
  --no-sort \
  --layout=reverse \
  --height=100% \
  --min-height=10 \
  --delimiter=$'\x1f' \
  --with-nth=2 \
  --prompt="${INITIAL_PROMPT}" \
  --pointer='▶' \
  --marker='★' \
  --header="${INITIAL_HEADER}" \
  --header-first \
  --preview="${CP_SCRIPTS}/cheatsheet_preview.sh {1} {q}" \
  --preview-window='down:30%:wrap' \
  --bind="start:reload($CP_SCRIPTS/dispatch.sh '')" \
  --bind="change:reload($CP_SCRIPTS/dispatch.sh {q})" \
  --bind="enter:execute-silent($CP_SCRIPTS/insert.sh paste {1})+abort" \
  --bind="ctrl-l:execute-silent($CP_SCRIPTS/insert.sh paste-literal {1})+abort" \
  --bind="ctrl-o:execute-silent($CP_SCRIPTS/insert.sh copy {1})+abort" \
  --bind="ctrl-p:execute-silent($CP_SCRIPTS/pin.sh {1})+reload($CP_SCRIPTS/dispatch.sh {q})" \
  --bind="ctrl-g:execute($CP_SCRIPTS/group_pick.sh)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)+transform-prompt($CP_SCRIPTS/prompt.sh)" \
  --bind="ctrl-a:execute($CP_SCRIPTS/action_palette.sh {1})+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)+transform-prompt($CP_SCRIPTS/prompt.sh)" \
  --bind="ctrl-s:execute-silent($CP_SCRIPTS/scope.sh toggle)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="shift-left:execute-silent($CP_SCRIPTS/scope.sh prev)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="shift-right:execute-silent($CP_SCRIPTS/scope.sh next)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="ctrl-t:execute-silent($CP_SCRIPTS/case.sh toggle)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-prompt($CP_SCRIPTS/prompt.sh)" \
  --bind="ctrl-r:execute-silent($CP_SCRIPTS/ingest.sh --force; python3 $CP_SCRIPTS/ingest_sessions.py </dev/null >/dev/null 2>&1 &)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="ctrl-e:execute-silent($CP_SCRIPTS/session_mode.sh)+change-preview-window(down:70%:wrap:follow|down:30%:wrap)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)+transform-prompt($CP_SCRIPTS/prompt.sh)" \
  --bind="ctrl-/:execute-silent($CP_SCRIPTS/similar_toggle.sh {1})+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)+transform-prompt($CP_SCRIPTS/prompt.sh)" \
  --bind="?:execute-silent($CP_SCRIPTS/cheatsheet_toggle.sh)+refresh-preview" \
  --bind="shift-up:preview-up" \
  --bind="shift-down:preview-down" \
  --bind="alt-up:preview-half-page-up" \
  --bind="alt-down:preview-half-page-down" \
  --bind="ctrl-]:change-preview-window(80%|hidden|down:30%:wrap)" \
  --bind="ctrl-q:abort" \
  --bind="alt-q:abort" \
  --bind="esc:abort"
