#!/usr/bin/env bash
# paths.sh — sourced by every script to establish canonical data/runtime paths.
# Honors XDG_DATA_HOME and XDG_RUNTIME_DIR with safe fallbacks.
# Idempotent: sourcing twice is a no-op (guard via CP_PATHS_LOADED).

[ "${CP_PATHS_LOADED:-}" = "1" ] && return 0
CP_PATHS_LOADED=1

# Data dir: persistent storage (DB lives here).
_cp_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
export CP_DATA_DIR="${_cp_data_home}/claude-prompts"

# Runtime dir: ephemeral state (scope file lives here).
# Fallback must be per-user and mode 0700 to avoid world-readable scope leakage.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  _cp_run_base="$XDG_RUNTIME_DIR"
else
  _cp_run_base="/tmp/claude-prompts-${USER:-$(id -un)}"
fi
export CP_RUN_DIR="${_cp_run_base}/claude-prompts"

# Derived paths — honor pre-set CP_DB env var (allows test overrides).
export CP_DB="${CP_DB:-${CP_DATA_DIR}/db.sqlite}"
export CP_SCOPE_FILE="${CP_RUN_DIR}/scope"
export CP_CASE_FILE="${CP_RUN_DIR}/case"
export CP_HISTORY="${CP_HISTORY:-${HOME}/.claude/history.jsonl}"

# Create dirs idempotently. Runtime dir gets 0700 for privacy when using /tmp fallback.
mkdir -p "${CP_DATA_DIR}"
mkdir -p "${CP_RUN_DIR}"
chmod 0700 "${CP_RUN_DIR}"
