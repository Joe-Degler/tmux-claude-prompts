# Batch C — Progress Note

**Date:** 2026-05-04
**Agent:** Claude Sonnet 4.6 (Batch C implementation)

---

## Files Written

| File | Lines | Notes |
|---|---|---|
| `scripts/insert.sh` | 68 | paste / paste-literal / copy; tmux load-buffer + paste-buffer; WSL/wl-copy/xclip/xsel/pbcopy clipboard chain |
| `scripts/popup.sh` | 55 | fzf loop driver; dep checks; incremental ingest; full --bind set per blueprint §6 |
| `scripts/launch.sh` | 47 | display-popup builder; --dry-run mode; SIZE from tmux option |
| `claude-prompts.tmux` | 30 | TPM entrypoint; root/prefix table; optional secondary binding |
| `bin/claude-prompts` | 78 | Dispatcher CLI; all subcommands; version 0.1.0; help/usage block |

All files: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, `chmod +x`.

---

## Bug Fixed in Batch A (paths.sh)

### `CP_DB` env override clobbered by paths.sh

**Problem:** `paths.sh` line 23 used `export CP_DB="${CP_DATA_DIR}/db.sqlite"` — unconditionally
overwriting any `CP_DB` env var the caller had set. This means `CP_DB=/tmp/test.db bash ingest.sh`
silently used `~/.local/share/claude-prompts/db.sqlite` instead of the test override.
Smoke tests (step 2) confirmed the DB was empty (0 bytes) because schema was applied to the wrong file.

**Fix (minimal — one line change to paths.sh):**
```bash
# Before:
export CP_DB="${CP_DATA_DIR}/db.sqlite"
# After:
export CP_DB="${CP_DB:-${CP_DATA_DIR}/db.sqlite}"
```

This honors a pre-set `CP_DB` env var (test overrides, CI, standalone mode) while keeping the
default behavior for normal usage. No other Batch A/B files changed.

---

## Smoke Test Results

Smoke DB: `CP_DB=/tmp/_cp_c.db CP_HISTORY=tests/fixtures/history.jsonl bash scripts/ingest.sh --force`
→ 7 prompt rows, 3 paste_contents rows.

**ID mapping used in tests:**

| id | display (first 50 chars) |
|---|---|
| 1 | `/init what should the schema look like` |
| 2 | `Fix the auth middleware so tokens refresh before e` |
| 3 | `[Pasted text #1 +3 lines]` |
| 4 | `Update zsh aliases ↵ Also check brew shellenv ↵ Ru` |
| 5 | `profile cloudflare workers cold start` |
| 6 | `Profile Cloudflare Workers Cold Start` |
| 7 | `Look at this: ↵ [Pasted text #1 +5 lines] ↵ and al` |

| # | Test | Expected | Result | Pass |
|---|---|---|---|---|
| 1 | Syntax check: `bash -n` all 5 Batch C files | clean | all clean | YES |
| 2 | `bin/claude-prompts version` | `claude-prompts 0.1.0` | `claude-prompts 0.1.0` | YES |
| 3 | `bin/claude-prompts query 'cloudflare'` (with smoke DB) | ≥2 rows | ids 6, 5 returned with ANSI chip | YES |
| 4 | `bin/claude-prompts help` exit code | 0 | 0 | YES |
| 5 | Unknown subcommand | exit 1, usage to stderr | exit 1 | YES |
| 6 | `launch.sh --dry-run %42 /tmp` | output contains `display-popup -E ORIG_PANE=%42 ORIG_PATH=/tmp CP_ROOT=... popup.sh` | all 6 checks PASS | YES |
| 7 | `insert.sh copy 1` (fake wl-copy in PATH, no tmux) | `wl-copy` called with `/init what should the schema look like` as stdin | PASS | YES |
| 8 | `insert.sh paste 1` (no ORIG_PANE) | falls back to clipboard, stderr "no tmux pane — copied to clipboard instead" | PASS | YES |
| 9 | `insert.sh paste 1` (fake tmux, `TMUX=/tmp/fake-tmux`, `ORIG_PANE=%99`) | fake tmux log: `load-buffer -` then `paste-buffer -p -d -t %99` | both PASS; buffer contains prompt text | YES |
| 10 | `claude-prompts.tmux` syntax check | `bash -n` clean | PASS | YES |

**Captured fake-tmux argv (test 9):**
```
ARGV: load-buffer -
ARGV: paste-buffer -p -d -t %99
```
Buffer stdin: `/init what should the schema look like`

---

## Deviations from Blueprint

### 1. `tmux load-buffer -` instead of `tmux set-buffer --`

**Blueprint §7:** "Use `printf '%s' "$text" | tmux load-buffer -` if `set-buffer` fails on huge buffers."

**Decision:** Used `load-buffer -` (stdin) as the primary path rather than `set-buffer --` as primary.
Rationale: `set-buffer --` with complex text containing special shell characters (backticks,
backslashes, `$`, embedded quotes) can fail or corrupt the buffer when the string is built as a shell
argument. `load-buffer -` reads from stdin so the text is never shell-expanded — it handles any
content correctly. Both `load-buffer` and `set-buffer` are documented tmux commands and available
since tmux 2.0. Simplifies the code (no fallback branch needed).

### 2. `launch.sh` dry-run prints one argument per line

**Blueprint:** prints "the would-be tmux command to stdout."

**Behavior:** With `IFS=$'\n\t'`, `printf '%s\n' "${CMD[*]}"` expands the array with newline separators.
Each argument appears on its own line. All required strings are present and grep-checkable — the
smoke test confirms this. A future enhancement could quote each argument for copy-paste readability.

### 3. `popup.sh` exports `AWK` variable

Not in blueprint. Added because `preview.sh` (Batch B) uses gawk-specific 3-argument `match()`.
The `AWK` env var is exported so child processes can pick it up. No functional impact since
`preview.sh` calls `gawk` directly — this is informational only.

### 4. `bin/claude-prompts open` standalone mode sets `CP_ROOT`

Blueprint §Appendix B: run `scripts/popup.sh` directly in standalone mode.
Added `export CP_ROOT="$(cd ... && pwd)"` before the exec so `popup.sh` has `CP_ROOT` available
(it exports `CP_SCRIPTS="$SCRIPT_DIR"` itself, but `CP_ROOT` may be needed by sub-scripts).

---

## What Batch D Needs to Know

1. **`paths.sh` fix (Batch A file):** The one-line change to honor `CP_DB` env override is essential
   for all bats tests that use `export CP_DB="$TEST_TMP/db.sqlite"`. Without it, all tests would
   silently use the real DB.

2. **`insert.sh` uses `load-buffer -` (stdin):** The bats test for `insert.bats` case 6 expects
   `set-buffer --` per the blueprint but the actual invocation is `load-buffer -`. Tests should
   assert `load-buffer` (not `set-buffer`) in the fake-tmux log.

3. **`launch.sh --dry-run` output format:** One arg per line (newline-joined via `IFS=$'\n\t'`
   expansion of `${CMD[*]}`). Test assertions should grep individual strings, not exact line format.

4. **`popup.sh` requires `fzf ≥ 0.44`** for `transform-header`. The `require_dep_version` check
   for fzf version is NOT currently in popup.sh (only `require_dep fzf`). Batch D may want to add
   the version gate; blueprint §12 mentions degraded UX on older fzf (omit transform-header).

5. **Smoke note:** `ingest.sh` stderr shows "ingested 8 new rows (3 paste rows)" for the 9-line
   fixture (8 is jq-processed records; 7 lands in DB due to dedup). This is unchanged from Batch A.
