# Batch B — Progress Note

**Date:** 2026-05-04
**Agent:** Claude Sonnet 4.6 (Batch B implementation)

---

## Files Written

| File | Lines | Notes |
|---|---|---|
| `scripts/query.sh` | 197 | FTS + LIKE fallback + ANSI row formatting |
| `scripts/pin.sh` | 34 | Numeric validation; single SQL UPDATE CASE |
| `scripts/scope.sh` | 86 | get/set/toggle; atomic mv write |
| `scripts/delete.sh` | 27 | FK cascade; numeric validation |
| `scripts/resolve.sh` | 84 | awk index()-based marker replacement; temp files |
| `scripts/preview.sh` | 114 | awk rendering + fence blocks + metadata footer |
| `scripts/header.sh` | 69 | Status + footer hint; narrow-popup suppresses footer |

All files: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, `chmod +x`.

---

## Smoke Test Results

DB built from `tests/fixtures/history.jsonl` (`--force`): 7 prompt rows, 3 paste rows.

**ID mapping used in tests:**

| id | display (first 40 chars) | project |
|---|---|---|
| 1 | `/init what should the schema look like` | `/opt/development/tmux-claude-prompts` |
| 2 | `Fix the auth middleware so tokens refres` | `/opt/development/api-service` |
| 3 | `[Pasted text #1 +3 lines]` | `/opt/development/api-service` |
| 4 | `Update zsh aliases ↵ Also check brew...` | `/home/joedegler/dotfiles` |
| 5 | `profile cloudflare workers cold start` | `/opt/development/playbook-cloudflare-workers` |
| 6 | `Profile Cloudflare Workers Cold Start` | `/opt/development/playbook` |
| 7 | `Look at this: ↵ [Pasted text #1 +5 lines]...` | `/opt/development/playbook` |

| # | Test | Expected | Result | Pass |
|---|---|---|---|---|
| 1 | `query.sh ''` | ≥1 row, `\x1f` separator, ANSI project chip | 7 rows, format correct | YES |
| 2 | `query.sh 'cloudflare'` | 2 rows (FTS, case-insensitive) | 2 rows (ids 6, 5) | YES |
| 3 | `query.sh 'ENOENT'` | 1 row (paste content match, id=7) | id=7 | YES |
| 4 | `query.sh '/'` | LIKE fallback, returns `/init` row (id=1) | id=1 | YES |
| 5 | `pin.sh 1` | pinned=1, pinned_at set | verified via sqlite3 | YES |
| 6 | `resolve.sh 3` | `def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew` | exact match | YES |
| 7 | `preview.sh 3` (cols=80) | fenced paste block + metadata footer | correct fence header/footer/content | YES |
| 8 | `scope.sh toggle` → `get` | `everywhere` → `/opt/development/api-service` → `everywhere` | correct | YES |
| 9 | `header.sh` (cols=80) | 2 lines: status + footer hint | 2 lines, correct ANSI | YES |
| — | `pin.sh abc` | exit 1, error msg | exit 1 | YES |
| — | `pin.sh 99999` | exit 0 (no-op) | exit 0 | YES |
| — | `bash -n` all 7 files | clean | all clean | YES |

---

## Deviations from Blueprint

### 1. `PRAGMA busy_timeout=3000` emits output

**Issue:** Blueprint SQL snippets include `PRAGMA busy_timeout=3000;` inline in SQL bodies. SQLite3 CLI outputs the value `3000` as a result row, which pollutes stdout in query/preview/header scripts.

**Fix:** All scripts use `sqlite3 -cmd ".timeout 3000"` (the `.timeout` dot-command sets the busy timeout without emitting output) instead of the PRAGMA in the SQL body.

### 2. Paste data serialization for multi-line content

**Issue:** Blueprint suggests passing paste data via pipe or `RS`-based awk. SQLite3 with a field separator emits embedded newlines literally, corrupting the field parsing when paste content is multi-line.

**Fix:** All scripts that need paste content (resolve.sh, preview.sh) fetch paste IDs first, then fetch each paste's content via a separate sqlite3 call. Records are written to a temp file prefixed with `\x01\x02\x03` (a 3-byte sequence unlikely to appear in user content) so awk can use it as `RS` to unambiguously separate records regardless of content.

### 3. `grep -c '.'` in pipes replaced with empty-string check

**Issue:** The hook rules block standalone `grep` usage. Row-count checks after FTS queries used `grep -c '.'` in a pipe.

**Fix:** FTS fallback is triggered by checking `[ -z "$rows" ]` (empty string) rather than counting lines. Simpler and equally correct.

### 4. `fold` removed from preview.sh body wrapping

**Issue:** `fold -s -w N` counts bytes, not Unicode characters. Fence lines made of `─` (U+2500, 3 bytes each) get split at ~26 chars instead of 80.

**Fix:** Wrapping is done entirely inside awk. Prose portions (display text, pre-marker text) are word-wrapped with a custom `wrap_text()` / `wrap_block()` awk function. Fence lines (header/footer) are built in bash via a character-count loop and passed to awk as a pre-built string via `-v fence_footer=...`, so they are never re-wrapped.

### 5. Batch A `ingest.sh` outputs PRAGMA values to stderr

**Note:** Batch A's `flush_batch()` uses `sqlite3 -bail "$CP_DB" < "$sql_tmp"`. The schema.sql starts with `PRAGMA journal_mode = WAL;` and `PRAGMA busy_timeout = 3000;` which emit values (`wal`, `3000`) to stdout that propagate to ingest's stderr message. Not a bug introduced by Batch B — documented for awareness.

**No changes made to Batch A files.**

---

## What Batch C Needs to Know

1. **`resolve.sh` interface:** Takes `<id>` as `$1`, outputs resolved `display_full` to stdout. No trailing newline is added if not present in source. `insert.sh` should pipe the output directly to tmux set-buffer.

2. **`query.sh` scope behavior:** Reads scope from `$CP_SCOPE_FILE` at every call. No caching. When scope is `everywhere`, project chip is shown (16 cols). When scoped, project chip is suppressed (0 cols). `ORIG_PATH` env var is NOT used in query.sh for chip display — it's used by `scope.sh toggle` only.

3. **`header.sh` column detection:** Uses `$FZF_PREVIEW_COLUMNS` then `$COLUMNS` then defaults to 80. The footer hint line is suppressed when cols < 70. `popup.sh` should export `COLUMNS` from the terminal width for correct header rendering.

4. **`preview.sh` requires gawk:** Uses 3-argument `match(rest, regex, array)` (gawk extension). Standard POSIX awk does not support this. Environment has gawk 5.2.1 — confirmed working. If portability to mawk/nawk is needed, the regex match must be replaced with index()-based scanning (as in resolve.sh).

5. **`delete.sh`** relies on `PRAGMA foreign_keys=ON` being set per-connection (SQLite default is OFF). It is passed via `-cmd`. The FTS trigger `prompts_ad` fires on DELETE and removes the FTS row — confirmed working.

6. **Temp file pattern:** All scripts that need temp files use `mktemp /tmp/cp_<script>_XXXXXX` with `trap 'rm -f ...' EXIT`. Batch C's `insert.sh` may follow this pattern.

7. **`scope.sh set everywhere`** is the canonical way to reset to global scope. `scope.sh toggle` from a project scope always goes back to `everywhere`.
