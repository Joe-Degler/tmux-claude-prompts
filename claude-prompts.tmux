#!/usr/bin/env bash
# claude-prompts.tmux — TPM entrypoint; registers tmux keybind(s).
# Source this file via `run-shell` in ~/.tmux.conf or via TPM.

set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# shellcheck source=scripts/helpers.sh
. "$SCRIPTS_DIR/helpers.sh"

key=$(get_option "@claude_prompts_key" "M-p")
table=$(get_option "@claude_prompts_key_table" "root")
prefix_key=$(get_option "@claude_prompts_prefix_key" "")

# Primary binding
if [ "$table" = "root" ]; then
  tmux bind-key -n "$key" \
    run-shell -b "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}' || true"
else
  tmux bind-key -T "$table" "$key" \
    run-shell -b "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}' || true"
fi

# Optional secondary binding under prefix (empty = disabled)
if [ -n "$prefix_key" ]; then
  tmux bind-key "$prefix_key" \
    run-shell -b "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}' || true"
fi
