#!/usr/bin/env bash
# cheatsheet_preview.sh — preview-pane router.
# When $CP_RUN_DIR/cheatsheet exists, render the keymap; in session mode,
# render the transcript preview; otherwise the normal row preview.
# Usage: cheatsheet_preview.sh <id> [<query>]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/paths.sh"

if [ -f "${CP_RUN_DIR}/cheatsheet" ]; then
  exec "${SCRIPT_DIR}/cheatsheet.sh"
fi

if [ -f "${CP_RUN_DIR}/sessions" ]; then
  exec "${SCRIPT_DIR}/session_preview.sh" "${1:-}" "${2:-}"
fi

exec "${SCRIPT_DIR}/preview.sh" "${1:-}"
