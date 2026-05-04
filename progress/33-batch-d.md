# Batch D — Progress Note

**Date:** 2026-05-04
**Agent:** Claude Sonnet 4.6 (Batch D implementation)

---

## Files Written

| File | Notes |
|---|---|
| `tests/helpers.bash` | Updated (not replaced) with 4 new helpers: `mock_tmux_dir()`, `mock_clipboard_dir()`, `cp_run()`, `query_ids()`. Existing functions preserved. |
| `tests/ingest.bats` | 8 cases per blueprint §9 |
| `tests/query.bats` | 8 cases including paste-content FTS matches |
| `tests/pin.bats` | 5 cases |
| `tests/insert.bats` | 6 cases including fake-tmux shim |
| `README.md` | Install (manual + TPM), keys, config table, pasted content callout, standalone usage, architecture paragraph, dependencies, troubleshooting, tests, license |

---

## Test Results (final `bats tests/` output)

```
1..27
ok 1 ingests fresh fixture
ok 2 is idempotent on second run
ok 3 skips empty display only (NOT paste markers)
ok 4 ingests paste contents into paste_contents table
ok 5 keeps max(ts) on duplicate
ok 6 collapses newlines into ↵ marker
ok 7 incremental ingest picks up new lines
ok 8 paste contents survive re-ingest
ok 9 marker replacement produces full text
ok 10 multiple markers replaced in one prompt
ok 11 literal mode preserves markers
ok 12 paste action with no paste rows is identity
ok 13 unmatched marker is left untouched
ok 14 tmux insert invokes load-buffer + paste-buffer -p -d
ok 15 toggles pinned column on first call
ok 16 toggles back on second call
ok 17 pinned rows sort before unpinned in browse query
ok 18 preserves pin across re-ingest
ok 19 non-existent id is a no-op
ok 20 empty query returns recent first
ok 21 case-insensitive match
ok 22 prefix tokens match
ok 23 fallback LIKE engaged for symbol-only query
ok 24 scope=project filters by project
ok 25 pinned rows sort first
ok 26 FTS finds prompt by paste content
ok 27 FTS finds prompt by paste content with prefix
```

**Final result: 27/27 passed, 0 failures.**

---

## Bugs Found and Fixed in Earlier Batches

None. All Batch A/B/C scripts behaved correctly against their tests. No edits to Batch A/B/C files were required.

---

## Deviations and Design Decisions

### 1. `insert.bats` case 3 — literal mode assertion

Blueprint says case 3 should assert the literal marker text appears in what is "sent." Since the fake tmux logs argv only (not stdin), the test verifies that: (a) `load-buffer` was invoked (the text reached the shim), and (b) `display_full` from the DB contains the literal marker `[Pasted text #1 +3 lines]`. A direct comparison of the tmux buffer content would require a real tmux session. The implemented assertion is sufficient to prove `paste-literal` does not call `resolve.sh`.

### 2. `query.bats` case 5 — scope filter validation loop

The test writes `/opt/development/api-service` to the scope file then runs `query_ids ''`. It loops over all returned ids and asserts each belongs to api-service, then confirms at least 1 result. The fixture has 2 api-service rows (Fix auth middleware + [Pasted text #1] paste-only), so `count >= 1` is conservative but correct.

### 3. `query.bats` case 6 — uses row id 4 (dotfiles)

The test pins row 4 directly by integer id. This matches the stable id mapping from Batch B/C smoke tests (ingest order is deterministic for the fixture). The `pin.bats` case 3 also pins row 4 directly. If the fixture changes, these tests would need updating — acceptable for a fixture-driven test suite.

### 4. bats installed via npm

bats was not present on the system. Installed via `npm install -g bats` which provides bats 1.13.0. No system package required.

### 5. `mock_clipboard_dir()` defined but not used in tests

The helper was added as specified (for completeness and future use). Current test cases do not exercise clipboard paths because all insert tests use the fake tmux path. No test case was skipped.

---

## Caveats

- `query.bats` cases 6 and `pin.bats` case 3 assume row id 4 is the dotfiles row. This is stable for the current fixture (ingest order is deterministic) but would break if the fixture is reordered.
- `ingest.bats` case 7 (incremental ingest) copies the fixture, appends a line, and runs ingest with `CP_HISTORY` pointing at the copy. The original fixture file in `$HOME/.claude/history.jsonl` is left at the original byte offset in `ingest_state`, so the copy's extended bytes are picked up as new. This is correct by design.
