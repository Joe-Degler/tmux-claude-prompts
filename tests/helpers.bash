#!/usr/bin/env bash
# tests/helpers.bash — bats test bootstrap.
# Provides load_fixtures(), teardown_fixtures(), setup_db(),
# mock_tmux_dir(), mock_clipboard_dir(), cp_run(), query_ids().

# Project root (absolute path, usable in test files)
CP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CP_ROOT

load_fixtures() {
  export TEST_TMP
  TEST_TMP="$(mktemp -d)"
  export XDG_DATA_HOME="$TEST_TMP/data"
  export XDG_RUNTIME_DIR="$TEST_TMP/run"
  export HOME_BACKUP="$HOME"
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
  cp "${BATS_TEST_DIRNAME}/fixtures/history.jsonl" "$HOME/.claude/history.jsonl"
  # Re-source paths.sh in the new HOME context so CP_* vars are fresh.
  # Unset the guard so paths.sh re-evaluates.
  unset CP_PATHS_LOADED CP_HELPERS_LOADED
  # shellcheck source=../scripts/paths.sh
  . "${CP_ROOT}/scripts/paths.sh"
  # shellcheck source=../scripts/helpers.sh
  . "${CP_ROOT}/scripts/helpers.sh"
}

teardown_fixtures() {
  rm -rf "$TEST_TMP"
  export HOME="$HOME_BACKUP"
  unset CP_PATHS_LOADED CP_HELPERS_LOADED TEST_TMP XDG_DATA_HOME XDG_RUNTIME_DIR HOME_BACKUP
}

# setup_db — runs ingest.sh against the fixture into the isolated $CP_DB.
# Call after load_fixtures().
setup_db() {
  CP_HISTORY="${BATS_TEST_DIRNAME}/fixtures/history.jsonl" \
    bash "${CP_ROOT}/scripts/ingest.sh" --force >/dev/null
}

# mock_tmux_dir — creates a tempdir containing a fake 'tmux' executable.
# The fake tmux logs each invocation's arguments (one arg per line) to $TMUX_LOG_FILE.
# Returns the tempdir path on stdout. Caller should prepend to PATH.
# Usage:
#   dir="$(mock_tmux_dir)"
#   export TMUX_LOG_FILE="$TEST_TMP/tmux.log"
#   export PATH="$dir:$PATH"
mock_tmux_dir() {
  local dir
  dir="$(mktemp -d)"
  cat > "$dir/tmux" <<'SHIM'
#!/usr/bin/env bash
# fake tmux — logs argv then succeeds
printf 'ARGV:' >> "${TMUX_LOG_FILE:-/tmp/fake_tmux.log}"
for arg in "$@"; do
  printf ' %s' "$arg" >> "${TMUX_LOG_FILE:-/tmp/fake_tmux.log}"
done
printf '\n' >> "${TMUX_LOG_FILE:-/tmp/fake_tmux.log}"
# For load-buffer -, read and discard stdin
if [ "${1:-}" = "load-buffer" ] && [ "${2:-}" = "-" ]; then
  cat > /dev/null
fi
exit 0
SHIM
  chmod +x "$dir/tmux"
  printf '%s' "$dir"
}

# mock_clipboard_dir — creates a tempdir containing fake clipboard tools.
# Each fake tool logs its stdin to $CLIP_LOG_FILE.
# Returns the tempdir path on stdout.
mock_clipboard_dir() {
  local dir
  dir="$(mktemp -d)"
  for tool in wl-copy xclip pbcopy clip.exe; do
    cat > "$dir/$tool" <<'SHIM'
#!/usr/bin/env bash
cat >> "${CLIP_LOG_FILE:-/tmp/fake_clip.log}"
exit 0
SHIM
    chmod +x "$dir/$tool"
  done
  # xclip needs to handle -selection clipboard flag
  cat > "$dir/xclip" <<'SHIM'
#!/usr/bin/env bash
cat >> "${CLIP_LOG_FILE:-/tmp/fake_clip.log}"
exit 0
SHIM
  chmod +x "$dir/xclip"
  printf '%s' "$dir"
}

# cp_run <subcommand...> — runs bin/claude-prompts with test env vars pre-set.
# CP_DB, CP_HISTORY, CP_SCOPE_FILE, CP_RUN_DIR are inherited from load_fixtures/setup_db.
cp_run() {
  CP_DB="$CP_DB" \
  CP_HISTORY="$CP_HISTORY" \
  CP_SCOPE_FILE="$CP_SCOPE_FILE" \
  CP_RUN_DIR="$CP_RUN_DIR" \
    bash "${CP_ROOT}/bin/claude-prompts" "$@"
}

# query_ids <query> — runs bin/claude-prompts query and emits one id per line.
# Extracts field 1 (before \x1f) from each output row.
query_ids() {
  cp_run query "$1" | awk -F'\x1f' '{print $1}'
}
