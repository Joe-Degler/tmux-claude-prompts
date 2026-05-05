#!/usr/bin/env bash
# action_palette.sh — Ctrl-A row-actions palette.
# Usage:
#   action_palette.sh <prompt_id>           interactive (nested fzf)
#   action_palette.sh <prompt_id> <verb>    non-interactive dispatch (used by tests)
#
# High-frequency verbs (pin, group-pick) are bound directly in popup.sh; this
# palette covers only the lower-frequency curation verbs:
#   group-add   Add/remove from active group
#   label       Set or clear the row's short label
#   delete      Delete this row from local store
#
# Mirrors the nested-fzf pattern from group_pick.sh.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

# Export for child scripts that look at $CP_SCRIPTS.
export CP_SCRIPTS="$SCRIPT_DIR"

PID="${1:-}"
VERB="${2:-}"

if [ -z "$PID" ] || ! printf '%s' "$PID" | grep -qE '^[0-9]+$'; then
  exit 0
fi

# Dispatch a verb to the right script. Returns whatever that script returns.
dispatch_verb() {
  local v="$1" pid="$2"
  case "$v" in
    group-add)  exec "${SCRIPT_DIR}/group_add.sh"  "$pid" ;;
    label)      exec "${SCRIPT_DIR}/label_set.sh"  "$pid" ;;
    delete)     exec "${SCRIPT_DIR}/delete.sh"     "$pid" ;;
    *)          exit 0 ;;
  esac
}

# Non-interactive path (tests / future scripted use).
if [ -n "$VERB" ]; then
  dispatch_verb "$VERB" "$PID"
fi

require_dep fzf

# Build the menu rows: <verb>\t<description>
# Adapt the group-add description based on whether a group is currently active.
group_active_suffix=""
if [ ! -f "${CP_RUN_DIR}/group" ]; then
  group_active_suffix="  (no group active — pick one first)"
fi

rows="$(printf '%s\n' \
  "group-add"$'\t'"Add/remove from active group${group_active_suffix}" \
  "label"$'\t'"Set or clear the row's short label" \
  "delete"$'\t'"Delete this row from local store")"

# Run nested fzf. --no-sort preserves the order above.
set +e
picked="$(printf '%s\n' "$rows" | fzf \
  --prompt='Action> ' \
  --header='Row actions — Enter to run, Esc to cancel' \
  --no-sort \
  --height=40% \
  --delimiter=$'\t' \
  --with-nth=1,2 \
  --layout=reverse)"
status=$?
set -e

# 0 = picked. 1 = nothing matched / no selection. 130 = aborted.
if [ "$status" -ne 0 ] || [ -z "$picked" ]; then
  exit 0
fi

verb="${picked%%$'\t'*}"
[ -z "$verb" ] && exit 0

dispatch_verb "$verb" "$PID"
