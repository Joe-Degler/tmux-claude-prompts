#!/usr/bin/env bash
# dispatch.sh — choose a search backend per fzf reload.
# Usage: dispatch.sh "<query>"
#
# Decision tree (in order):
#  -1. Session mode active ($CP_RUN_DIR/sessions exists)
#        → session_query.sh <query>          (transcript search, one row per session)
#   0. Group mode active ($CP_RUN_DIR/group holds a group id)
#        → group.sh <gid> <query>            (members of group, query refines)
#   1. Similar mode active ($CP_RUN_DIR/similar holds an id)
#        → similar.sh <id> <query>          (semantic neighbors, query refines)
#   2. Empty query
#        → query.sh ""                       (browse: pinned then recent)
#   3. Case-sensitive mode
#        → query.sh "<query>"                (byte-wise lexical, no embeddings)
#   4. Default: try daemon-backed hybrid (FTS5 + vec via RRF, pinned-on-top)
#        → python embed.py call-hybrid-rendered (daemon returns formatted rows)
#      Daemon unreachable → query.sh "<query>" (lexical fallback)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

Q="${1:-}"

# (-1) Session mode — searches transcripts, not prompts; trumps all others.
if [ -f "${CP_RUN_DIR}/sessions" ]; then
  exec "${SCRIPT_DIR}/session_query.sh" "$Q"
fi

# (0) Group mode — member filter trumps everything else, query refines.
group_file="${CP_RUN_DIR}/group"
if [ -f "$group_file" ]; then
  group_id="$(< "$group_file")"
  if [ -n "$group_id" ]; then
    exec "${SCRIPT_DIR}/group.sh" "$group_id" "$Q"
  fi
fi

# (1) Similar mode
similar_file="${CP_RUN_DIR}/similar"
if [ -f "$similar_file" ]; then
  source_id="$(cat "$similar_file" 2>/dev/null || true)"
  if [ -n "$source_id" ]; then
    exec "${SCRIPT_DIR}/similar.sh" "$source_id" "$Q"
  fi
fi

# (2) Empty query → browse
if [ -z "$Q" ]; then
  exec "${SCRIPT_DIR}/query.sh" ""
fi

# (3) Case-sensitive → lexical only (vec tokenizer normalizes case)
case_mode="insensitive"
if [ -f "$CP_CASE_FILE" ]; then
  case_mode="$(cat "$CP_CASE_FILE" 2>/dev/null || true)"
fi
if [ "$case_mode" = "sensitive" ]; then
  exec "${SCRIPT_DIR}/query.sh" "$Q"
fi

# (4) Hybrid via daemon, with lexical fallback.
# Skip embed.sh's venv-bootstrap shell (~30 ms): on hot path the venv
# already exists. Fall back to query.sh on any failure.
VENV_PY="${CP_VENV_DIR:-${CP_DATA_DIR}/.venv}/bin/python"
if [ ! -x "$VENV_PY" ]; then
  exec "${SCRIPT_DIR}/query.sh" "$Q"
fi

# Pass the glyph mode through so the daemon renders ASCII when configured.
. "${SCRIPT_DIR}/glyphs.sh"
no_nerd_flag=()
if [ "${GLYPHS[trunc]}" = "..." ]; then
  no_nerd_flag=(--no-nerd)
fi

scope="everywhere"
if [ -f "$CP_SCOPE_FILE" ]; then
  scope="$(cat "$CP_SCOPE_FILE")"
fi
[ -z "$scope" ] && scope="everywhere"

tmp_out="$(mktemp /tmp/cp_dispatch_XXXXXX)"
trap 'rm -f "$tmp_out"' EXIT
if ! "$VENV_PY" "${SCRIPT_DIR}/embed.py" call-hybrid-rendered "$Q" --limit 200 --scope "$scope" "${no_nerd_flag[@]}" > "$tmp_out" 2>/dev/null; then
  exec "${SCRIPT_DIR}/query.sh" "$Q"
fi
if [ ! -s "$tmp_out" ]; then
  exec "${SCRIPT_DIR}/query.sh" "$Q"
fi
cat "$tmp_out"
