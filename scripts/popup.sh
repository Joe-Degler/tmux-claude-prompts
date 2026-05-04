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

# --- Prompt glyph ---
if [ "${GLYPHS[proj]}" = ">" ]; then
  PROMPT_STR=" > "
else
  PROMPT_STR="  "
fi

# --- Initial header ---
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
  --prompt="${PROMPT_STR}" \
  --pointer='▶' \
  --marker='★' \
  --header="${INITIAL_HEADER}" \
  --header-first \
  --preview="${CP_SCRIPTS}/preview.sh {1}" \
  --preview-window='down:20%:wrap' \
  --bind="start:reload($CP_SCRIPTS/query.sh '')" \
  --bind="change:reload($CP_SCRIPTS/query.sh {q})" \
  --bind="enter:execute-silent($CP_SCRIPTS/insert.sh paste {1})+abort" \
  --bind="ctrl-l:execute-silent($CP_SCRIPTS/insert.sh paste-literal {1})+abort" \
  --bind="ctrl-o:execute-silent($CP_SCRIPTS/insert.sh copy {1})+abort" \
  --bind="ctrl-p:execute-silent($CP_SCRIPTS/pin.sh {1})+reload($CP_SCRIPTS/query.sh {q})" \
  --bind="ctrl-s:execute-silent($CP_SCRIPTS/scope.sh toggle)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="shift-left:execute-silent($CP_SCRIPTS/scope.sh prev)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="shift-right:execute-silent($CP_SCRIPTS/scope.sh next)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="ctrl-t:execute-silent($CP_SCRIPTS/case.sh toggle)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="ctrl-d:execute-silent($CP_SCRIPTS/delete.sh {1})+reload($CP_SCRIPTS/query.sh {q})" \
  --bind="ctrl-r:execute-silent($CP_SCRIPTS/ingest.sh --force)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="?:toggle-preview" \
  --bind="esc:abort" \
  --bind="ctrl-q:abort"
