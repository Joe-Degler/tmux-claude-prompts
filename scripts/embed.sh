#!/usr/bin/env bash
# embed.sh — venv-bootstrapping wrapper around embed.py.
#
# Lazily creates $CP_DATA_DIR/.venv and pip-installs fastembed + sqlite-vec
# on first run, then execs the venv's python on embed.py with passthrough args.
#
# Idempotent: a marker file ($CP_DATA_DIR/.venv/.deps-ok) records which dep
# set is satisfied so subsequent runs skip the pip step.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep python3

VENV_DIR="${CP_VENV_DIR:-${CP_DATA_DIR}/.venv}"
MARKER="${VENV_DIR}/.deps-ok"
DEPS=(fastembed==0.4.* sqlite-vec==0.1.*)
DEPS_HASH="$(printf '%s\n' "${DEPS[@]}" | sha1sum | cut -c1-12)"

if [ ! -x "${VENV_DIR}/bin/python" ]; then
  printf 'embed.sh: creating venv at %s\n' "$VENV_DIR" >&2
  python3 -m venv "$VENV_DIR" >&2
fi

if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER" 2>/dev/null || true)" != "$DEPS_HASH" ]; then
  printf 'embed.sh: installing python deps (one-time, ~few minutes)…\n' >&2
  "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip >&2
  "${VENV_DIR}/bin/python" -m pip install --quiet "${DEPS[@]}" >&2
  printf '%s' "$DEPS_HASH" > "$MARKER"
fi

# `kickoff` is a convenience verb (not exposed by embed.py): ensure the
# daemon is running, then send backfill-async. Used by popup.sh in the
# background so popup open is never blocked by model load.
if [ "${1:-}" = "kickoff" ]; then
  if "${VENV_DIR}/bin/python" "${SCRIPT_DIR}/embed.py" daemon-ensure; then
    "${VENV_DIR}/bin/python" "${SCRIPT_DIR}/embed.py" call-backfill-async >/dev/null 2>&1 || true
  fi
  exit 0
fi

exec "${VENV_DIR}/bin/python" "${SCRIPT_DIR}/embed.py" "$@"
