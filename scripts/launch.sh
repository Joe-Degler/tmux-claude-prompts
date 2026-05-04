#!/usr/bin/env bash
# launch.sh — run OUTSIDE the popup; captures env vars and invokes tmux display-popup.
# Usage: launch.sh [--dry-run] <orig_pane> <orig_path>
# The --dry-run flag prints the would-be tmux command to stdout instead of executing it.

set -euo pipefail
IFS=$'\n\t'

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

ORIG_PANE="${1:-}"
ORIG_PATH="${2:-$HOME}"

# Read popup size from tmux option (only if tmux is running)
SIZE=""
if [ -n "${TMUX:-}" ]; then
  SIZE="$(tmux show-option -gqv "@claude_prompts_popup_size" 2>/dev/null || true)"
fi
SIZE="${SIZE:-90%}"

CMD=(
  tmux display-popup
  -E
  -w "$SIZE"
  -h "$SIZE"
  -b rounded
  -T " Claude Prompts "
  -d "$ORIG_PATH"
  -e "ORIG_PANE=$ORIG_PANE"
  -e "ORIG_PATH=$ORIG_PATH"
  -e "CP_ROOT=$CURRENT_DIR"
  --
  bash "${CURRENT_DIR}/scripts/popup.sh"
)

if [ "$DRY_RUN" -eq 1 ]; then
  # Print the command components separated by spaces (quoted for readability)
  printf '%s\n' "${CMD[*]}"
else
  exec "${CMD[@]}"
fi
