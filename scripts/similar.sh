#!/usr/bin/env bash
# similar.sh — emit fzf-formatted rows ranked by semantic similarity to <id>.
# Usage: similar.sh <id> [<refine_query>]
#
# Strategy:
#   1. Try daemon (embed.sh call-knn-id) first — fast (no model reload).
#   2. On daemon failure, fall back to direct embed.py search-id (slower:
#      pays model load cost in the calling process, but works without daemon).
#   3. Pipe the resulting id list through render_ids.sh, which preserves
#      rank order and optionally AND-filters by <refine_query>.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

SOURCE_ID="${1:-}"
REFINE_Q="${2:-}"

if [ -z "$SOURCE_ID" ]; then
  exit 0
fi

# qlen = whitespace-stripped length of the typed AND-filter query, used as a
# recency-weighting hint by the daemon. The FTS MATCH refinement still happens
# downstream in render_ids.sh; this only steers the KNN ordering.
stripped_q="$(printf '%s' "$REFINE_Q" | tr -d '[:space:]')"
QLEN="${#stripped_q}"

# Prefer daemon (fast); fall back to direct mode.
ids="$("${SCRIPT_DIR}/embed.sh" call-knn-id "$SOURCE_ID" --limit 200 --qlen "$QLEN" 2>/dev/null || true)"
if [ -z "$ids" ]; then
  ids="$("${SCRIPT_DIR}/embed.sh" search-id "$SOURCE_ID" --limit 200 --qlen "$QLEN" 2>/dev/null || true)"
fi
if [ -z "$ids" ]; then
  exit 0
fi

printf '%s\n' "$ids" | "${SCRIPT_DIR}/render_ids.sh" "$REFINE_Q"
