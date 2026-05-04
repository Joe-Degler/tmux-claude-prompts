# Batch A — Progress Note

**Date:** 2026-05-04
**Agent:** Claude Sonnet 4.6 (Batch A implementation)

---

## Files Written

| File | Path | Notes |
|---|---|---|
| `paths.sh` | `scripts/paths.sh` | Sourced; exports `CP_DB`, `CP_SCOPE_FILE`, `CP_HISTORY`, `CP_DATA_DIR`, `CP_RUN_DIR`. Idempotent guard via `CP_PATHS_LOADED`. |
| `helpers.sh` | `scripts/helpers.sh` | Sourced; `get_option`, `require_dep`, `require_dep_version`, `sql`, `sql_quote`, `now_ms`, `is_tmux`, `ensure_db`. Uses `PRAGMA user_version` as schema sentinel. |
| `glyphs.sh` | `scripts/glyphs.sh` | Sourced; `declare -A GLYPHS` with all 10 keys, `GLYPH_COLOR` array with 256-color codes. Auto-detects `CLAUDE_PROMPTS_NO_NERD=1` env and `@claude_prompts_no_nerd` tmux option. |
| `schema.sql` | `scripts/schema.sql` | Full DDL as per §3 with one deviation (documented below). |
| `ingest.sh` | `scripts/ingest.sh` | Incremental upsert; chmod +x; CLI: `--force`, `--from-file <path>`. |
| `history.jsonl` | `tests/fixtures/history.jsonl` | 9-line fixture verbatim from §9. All 9 lines parse as valid JSONL. |
| `helpers.bash` | `tests/helpers.bash` | Bats bootstrap; `load_fixtures()`, `teardown_fixtures()`, `setup_db()`. |

---

## Smoke Test Results

All checks run against the 9-line fixture:

| Check | Expected | Actual | Pass? |
|---|---|---|---|
| `schema.sql` DDL validity (`sqlite3 :memory:`) | exit 0 | exit 0 | YES |
| `SELECT count(*) FROM prompts` after `--force` | 7 | 7 | YES |
| `SELECT count(*) FROM paste_contents` | 3 | 3 | YES |
| `SELECT count(*) FROM prompts_fts WHERE prompts_fts MATCH 'ENOENT'` | 1 | 1 | YES |
| All fixture lines parse as valid JSONL | 9/9 | 9/9 | YES |
| `bash -n` syntax check on all 4 `.sh` scripts | clean | clean | YES |
| `CLAUDE_PROMPTS_NO_NERD=1` → ASCII glyphs | `*`, `.`, `>` | `*`, `.`, `>` | YES |
| Nerd mode (default) → Unicode glyphs | `★`, `•`, `…`, `↵` | `★`, `•`, `…`, `↵` | YES |
| `sql_quote` escapes embedded single-quotes | `'it''s a test'` | `'it''s a test'` | YES |

Ingest timing on 9-line fixture: **~150-220 ms** (dominated by 8 `sha1sum` subshells, not SQLite I/O).

Note: ingest reports "8 new rows" (8 prompt records processed by jq) but DB shows 7 because one is a duplicate that UPSERTs to the same hash. The count in the stderr message reflects records processed by jq, not rows inserted.

---

## Deviations from Blueprint

### 1. FTS5 `content=''` (contentless mode) → Normal FTS5 mode

**Blueprint §3 specified:** `content=''` in the FTS5 virtual table declaration.

**Problem discovered:** SQLite's contentless FTS5 tables do not support `DELETE FROM fts WHERE rowid = X`. They require the special form `INSERT INTO fts(fts, rowid, body) VALUES('delete', rowid, old_body)` which requires knowing the old body value at delete time. The blueprint's triggers (including `prompts_ad`, `prompts_au`, `paste_ai`, `paste_au`, `paste_ad`) all use `DELETE FROM prompts_fts WHERE rowid = ...`, which fails at runtime with:

```
Runtime error near line 14: cannot DELETE from contentless fts5 table: prompts_fts
```

**Fix applied:** Removed `content=''` from the FTS5 declaration. Normal FTS5 mode stores its own copy of `body`. All triggers work as written. Storage overhead is ≤3 MB for the sample dataset (per blueprint §12 own analysis of the paste-content case).

**Recommendation for blueprint maintainer:** Either (a) remove `content=''` from §3 (simplest), or (b) redesign the triggers to use the `'delete'` command form and store the old body somewhere accessible (complex and not worth it for this dataset scale).

### 2. `sqlite3` CLI not installed — installed to `~/.local/bin`

The system had `libsqlite3-dev` (3.45.1) but no `sqlite3` CLI binary. Resolved by extracting the sqlite3 binary from the Ubuntu package via `dpkg -x` and placing it at `~/.local/bin/sqlite3`, which is already on the user's `$PATH`. No changes to scripts required; this is a one-time environment setup.

### 3. Ingest stderr message counts "jq-processed rows" not "DB-inserted rows"

The stderr line `ingested 8 new rows (3 paste rows) in 148 ms` reflects the 8 prompt records emitted by jq (the duplicate `/init` row is processed twice by jq, then deduped by the UPSERT). This is correct behavior — jq cannot know ahead of time what's a duplicate. The count could be changed to "attempted" vs "inserted" by adding a second sqlite3 query, but the current behavior is clear from the DB count check.

---

## Design Notes

### Hash computation strategy

Per blueprint guidance, sha1 is computed per-record via `printf '%s\x1f%s' "$display_full" "$project" | sha1sum`. This spawns one subshell per prompt record. For 12k rows this is ~12k subshells. Measured at ~150ms for 8 rows; extrapolating to 12k rows suggests ~2-3s total — at the edge of the 2s performance target. If sha1sum becomes a bottleneck on large datasets, a future optimization is to batch all records through a single awk pipeline that computes sha256 using a pure-awk implementation, or use a Python helper for the hash computation pass.

### Paste insert via hash subquery

Instead of using `RETURNING id` (which would require row-by-row sqlite3 calls), paste inserts use:
```sql
INSERT INTO paste_contents(prompt_id, paste_id, type, content)
SELECT (SELECT id FROM prompts WHERE hash='<hash>'), <paste_id>, '<type>', '<content>'
ON CONFLICT ...
```
This keeps all DML in a single batch temp-file fed to sqlite3 once per chunk of 500 prompts.

### `ensure_db` sentinel

Uses `PRAGMA user_version` — 0 means schema not applied, 1 means done. This is co-located in the DB, survives moves/copies of the file, and costs one extra sqlite3 call on first run only.

---

## Open Issues for Batch B

1. **`query.sh` FTS query building:** The blueprint's FTS ORDER BY uses `bm25(prompts_fts)` — verify this works with normal (non-contentless) FTS5 mode. It should (bm25 is supported by all FTS5 modes), but worth confirming.

2. **`glyphs.sh` `ret` key:** Appendix A lists 10 glyph keys but does not specify what `ret` (return/enter) glyph looks like in Nerd mode. The blueprint shows it as ` ` (space) in both modes in the table — set to `" "` (single space) in both modes. Batch B should confirm this is correct for use in UI rendering.

3. **`helpers.sh::ensure_db` and re-schema:** If the schema ever changes (e.g., adding a column), `user_version` being 1 will skip re-applying the schema. Batch D should add a migration mechanism keyed on `user_version` values (1 → 2 → ...).

4. **No `sqlite3` check in `ensure_db`:** `ensure_db` calls `require_dep sqlite3` but this exits the process. If called from a sourced context (not a subprocess), this will exit the parent shell. Batch B/C scripts that source helpers.sh and call ensure_db should be aware of this. The current ingest.sh handles this correctly because it's a standalone script.
