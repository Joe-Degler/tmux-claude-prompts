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

# --- Incremental ingest (stderr flows to popup terminal so user sees progress) ---
"${CP_SCRIPTS}/ingest.sh" >&2 || true

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

# --- Initial prompt and header (computed once; refreshed by transform-* binds) ---
INITIAL_PROMPT="$("${CP_SCRIPTS}/prompt.sh")"
INITIAL_HEADER="$("${CP_SCRIPTS}/header.sh")"

# --- fzf invocation (exec so this bash process is replaced) ---
exec fzf \
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
  --preview="${CP_SCRIPTS}/cheatsheet_preview.sh {1}" \
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
  --bind="ctrl-r:execute-silent($CP_SCRIPTS/ingest.sh --force)+reload($CP_SCRIPTS/dispatch.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
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
