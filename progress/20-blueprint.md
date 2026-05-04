# Implementation Blueprint — Claude Prompt Browser (`tmux-claude-prompts`)

**Date:** 2026-05-04
**Source docs:** `10-research-tmux.md`, `11-research-tech.md`, `12-design-ui.md`, `00-orchestration.md`
**Audience:** the build agents (Batches A–D). Read this end-to-end; do not re-read the research docs.

---

## 1. Reconciliation

The three research docs are mostly compatible. Conflicts and final decisions:

1. **Repo location vs. plugin name.** R1 uses `tmux-claude-prompts/` everywhere; user instruction names the working dir `/opt/development/tmux-claude-prompts`. **Decision:** repo + symlink name = `tmux-claude-prompts`; entrypoint file = `claude-prompts.tmux`.

2. **Where the popup is launched.** R1 has `claude-prompts.tmux` bind directly to `scripts/popup.sh`. Spec asks for a separate `launch.sh` that prepares env vars, then runs `display-popup` whose body is `popup.sh` (the fzf loop). **Decision:** keep them separated.
   - `scripts/launch.sh` runs *outside* the popup. Captures `ORIG_PANE`, computes `ORIG_PATH`, calls `tmux display-popup -E -e ... -- popup.sh`.
   - `scripts/popup.sh` runs *inside* the popup. Drives the fzf loop.

3. **Send-back: action inside popup vs. after exit.** R1 sketches both; UI spec wants Enter/Ctrl-O to close cleanly. **Decision:** action runs *inside* the popup, before fzf returns, via `--bind 'enter:execute-silent(insert.sh ...)+abort'`. Popup then closes via `-E`. Cleaner — no exit-code parsing in launch.sh.

4. **Default key.** R1 default `M-p` (root table). UI/UX doc accepts that. **Decision:** `M-p` root, override via `@claude_prompts_key` and `@claude_prompts_key_table`. Optional secondary `prefix + p` via `@claude_prompts_prefix_key` (default empty = disabled).

5. **Insert action keybinding.** UI doc says Enter inserts (paste, no submit), Ctrl-O copies. R2 sketch has Ctrl-Y for copy. **Decision:** follow UI doc — Enter = paste, Ctrl-O = copy. Ctrl-Y removed.

6. **Scope file location.** R2 picks `$XDG_RUNTIME_DIR/claude-prompts.scope`; spec says `$XDG_RUNTIME_DIR/claude-prompts/scope` (subdir). **Decision:** spec wins. `$XDG_RUNTIME_DIR/claude-prompts/scope` (fallback `/tmp/claude-prompts-$USER/scope`). Sentinel `everywhere` = global; otherwise an absolute project path.

7. **Header rendering.** UI doc sets `--header-first` and a multi-line header (status + footer). Trailing footer line in `--header` is the only way to get a footer with fzf. **Decision:** all chrome (status line + keymap hint) goes in `--header`; preview-window stays on bottom for prompt body.

8. **Preview content.** R2 used `echo {4}`. UI doc wants wrapped preview with metadata footer (`project · age · line count`). **Decision:** `--preview` calls `scripts/preview.sh {1}` (id-driven), which queries SQLite for the full row and renders wrapped body + dim metadata. `{4}` is no longer needed.

9. **Row format / `--with-nth`.** R2 wraps with tab delimiter and `--with-nth '2,3'`. We need the rendered text to be a single pre-formatted column (pin glyph + recency glyph + project chip + collapsed text) with ANSI color, to keep widths stable. **Decision:** two columns separated by `\x1f` (US, 0x1f):
   - field 1 = `id` (hidden)
   - field 2 = pre-rendered display line (ANSI-colored, fixed-width project chip, collapsed prompt text). fzf shows field 2 only.
   - `--delimiter $'\x1f' --with-nth 2`.

10. **High-level architecture (confirmed):**
    `tmux key` → `launch.sh` (captures `ORIG_PANE`, computes `ORIG_PATH`) → `tmux display-popup -E -e ... popup.sh` → `popup.sh` runs ingest then `fzf --disabled` with `change:reload(query.sh {q})` → on Enter, fzf binds `execute-silent(insert.sh)+abort` which invokes `tmux set-buffer + paste-buffer -p -d -t $ORIG_PANE`.

11. **Pasted content is first-class** (per coordinator update). `pastedContents` is an object keyed by paste-id, present on ~5% of rows, with shape `{"1": {"id":1, "type":"text", "content":"..."}, ...}`. The `display` field contains markers `[Pasted text #N +M lines]` referring to those keys. **Decisions:**
    - Do **not** skip rows whose display is purely a paste marker — they are the highest-value rows for the user.
    - Store paste bodies in a normalized `paste_contents` table.
    - Index paste content in FTS5 alongside `display` so search finds prompts by their pasted content.
    - List view keeps markers as-is (size-hinted).
    - Preview pane resolves markers and inlines the full paste body as a fenced block.
    - Default Enter inserts the **resolved** prompt (markers replaced with content). New `Ctrl-L` keybind inserts the raw markers untouched.
    Marker regex: `\[Pasted text #([0-9]+)( \+[0-9]+ lines)?\]`.

---

## 2. Repository layout

```
tmux-claude-prompts/
├── claude-prompts.tmux            # TPM entrypoint; registers keybind(s). chmod +x.
├── bin/
│   └── claude-prompts             # Dispatcher CLI: open|ingest|pin|scope|query|insert|version
├── scripts/
│   ├── launch.sh                  # Outside-popup: captures ORIG_PANE, runs display-popup
│   ├── popup.sh                   # Inside-popup: ingest sweep + fzf loop
│   ├── query.sh                   # Per-keystroke: emits fzf-formatted rows for query+scope
│   ├── ingest.sh                  # Incremental upsert from history.jsonl
│   ├── pin.sh                     # Toggle pinned bit for a row id
│   ├── scope.sh                   # Toggle scope between everywhere and current project
│   ├── insert.sh                  # set-buffer + paste-buffer (or clipboard fallback)
│   ├── resolve.sh                 # Resolves [Pasted text #N] markers using paste_contents
│   ├── delete.sh                  # Remove a row by id (Ctrl-D action)
│   ├── preview.sh                 # Render preview pane content for a row id (with paste expansion)
│   ├── header.sh                  # Render fzf header (status + footer hint)
│   ├── glyphs.sh                  # SOURCED. GLYPHS associative array (Nerd vs ASCII).
│   ├── paths.sh                   # SOURCED. XDG paths, db path, scope path, history path.
│   ├── helpers.sh                 # SOURCED. get_option, dep checks, sql wrapper.
│   └── schema.sql                 # CREATE TABLE / FTS5 / triggers (applied idempotently).
├── tests/
│   ├── helpers.bash               # Test bootstrap: sets HOME-isolated XDG dirs, sources libs.
│   ├── fixtures/
│   │   └── history.jsonl          # 8 hand-crafted lines covering edge cases.
│   ├── ingest.bats
│   ├── query.bats
│   ├── pin.bats
│   └── insert.bats
├── progress/                      # (already exists)
└── README.md                      # Install, keys, env vars, troubleshooting.
```

**Justification for deviations from the suggested skeleton:**
- Added `preview.sh`, `header.sh`, `delete.sh` because the UI spec demands them (multi-line wrapped preview with metadata, scope-aware status line, Ctrl-D delete).
- Kept `helpers.sh` separate from `paths.sh` for clarity: paths are pure constants; helpers does work.
- No `lib/` — flat `scripts/` is sufficient.

---

## 3. Data model & SQL

**DB path:** `${XDG_DATA_HOME:-$HOME/.local/share}/claude-prompts/db.sqlite`
**Source jsonl:** `$HOME/.claude/history.jsonl`
**Scope file:** `${XDG_RUNTIME_DIR:-/tmp}/claude-prompts/scope` (contents: `everywhere` or absolute path)
**Ingest offset:** stored in DB table `ingest_state` (single row keyed `byte_offset`). No separate file — keeps state co-located, atomic with ingest transaction.

### `scripts/schema.sql` (verbatim)

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS prompts (
  id        INTEGER PRIMARY KEY,
  display   TEXT    NOT NULL,                      -- newlines collapsed (' ↵ ' marker)
  display_full TEXT NOT NULL,                      -- original, with newlines preserved
  project   TEXT    NOT NULL DEFAULT '',
  ts        INTEGER NOT NULL,                      -- ms epoch, max(timestamp) per (display,project)
  pinned    INTEGER NOT NULL DEFAULT 0,
  pinned_at INTEGER,                               -- ms epoch when pinned, NULL otherwise
  hash      TEXT    NOT NULL UNIQUE                -- sha1(display_full || '\x1f' || project)
);

CREATE INDEX IF NOT EXISTS idx_prompts_ts      ON prompts(ts DESC);
CREATE INDEX IF NOT EXISTS idx_prompts_project ON prompts(project);
CREATE INDEX IF NOT EXISTS idx_prompts_pinned  ON prompts(pinned DESC, ts DESC);

CREATE TABLE IF NOT EXISTS paste_contents (
  prompt_id INTEGER NOT NULL,
  paste_id  INTEGER NOT NULL,
  type      TEXT    NOT NULL DEFAULT 'text',
  content   TEXT    NOT NULL,
  PRIMARY KEY (prompt_id, paste_id),
  FOREIGN KEY (prompt_id) REFERENCES prompts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_paste_prompt ON paste_contents(prompt_id);

CREATE TABLE IF NOT EXISTS ingest_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- FTS5 indexes display + concatenated paste contents.
-- Use 'contentless-delete' style: external content table is `prompts`,
-- but the indexed body is composed at trigger time.
CREATE VIRTUAL TABLE IF NOT EXISTS prompts_fts USING fts5(
  body,
  content='',                                     -- contentless: we drive it explicitly via triggers
  tokenize='unicode61 remove_diacritics 2'
);

-- Helper view used by triggers to compose the indexed body.
-- Kept as inline subqueries in the triggers (no CREATE VIEW needed).

-- INSERT on prompts → insert composed body into FTS
CREATE TRIGGER IF NOT EXISTS prompts_ai AFTER INSERT ON prompts BEGIN
  INSERT INTO prompts_fts(rowid, body) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    )
  );
END;

-- DELETE on prompts → delete from FTS (paste_contents cascade fires next)
CREATE TRIGGER IF NOT EXISTS prompts_ad AFTER DELETE ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
END;

-- UPDATE on prompts → re-index
CREATE TRIGGER IF NOT EXISTS prompts_au AFTER UPDATE OF display ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
  INSERT INTO prompts_fts(rowid, body) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    )
  );
END;

-- INSERT on paste_contents → re-index parent prompt
CREATE TRIGGER IF NOT EXISTS paste_ai AFTER INSERT ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         )
  FROM prompts p WHERE p.id = new.prompt_id;
END;

-- UPDATE on paste_contents → re-index
CREATE TRIGGER IF NOT EXISTS paste_au AFTER UPDATE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         )
  FROM prompts p WHERE p.id = new.prompt_id;
END;

-- DELETE on paste_contents → re-index parent (if it still exists)
CREATE TRIGGER IF NOT EXISTS paste_ad AFTER DELETE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.prompt_id;
  INSERT INTO prompts_fts(rowid, body)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         )
  FROM prompts p WHERE p.id = old.prompt_id;
END;
```

**Note on FTS5 contentless mode:** because we use `content=''`, FTS5 stores its own copy of `body`. This costs roughly the size of paste contents (manageable — paste bodies in the sample dataset total <1 MB). Alternative: external-content with a composing view, but contentless is simpler and bulletproof against trigger ordering. Going with contentless.

### Deduplication rule

Keyed on `(display_full, project)` via the `hash` UNIQUE column (`sha1(display_full + 0x1f + project)`).
Upsert pattern:

```sql
INSERT INTO prompts (display, display_full, project, ts, hash)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(hash) DO UPDATE SET
  ts = MAX(prompts.ts, excluded.ts)
RETURNING id;
```

This collapses repeated identical prompts (the `/compact` problem from R2) to one row, preserving the most recent timestamp. Pin state survives because the row id is stable across re-ingests.

The `RETURNING id` clause gives ingest the id needed to insert paste rows. Paste contents for a given prompt are also upserted by `(prompt_id, paste_id)` primary key — re-running ingest on a row that already has paste rows is idempotent (no duplicates, content overwritten if it changed).

```sql
INSERT INTO paste_contents (prompt_id, paste_id, type, content)
VALUES (?, ?, ?, ?)
ON CONFLICT(prompt_id, paste_id) DO UPDATE SET
  type    = excluded.type,
  content = excluded.content;
```

### Pin state location

Column `pinned` (0/1) and `pinned_at` (ms epoch, nullable) on `prompts`. Survives re-ingest because hash is the natural key. Not in FTS5.

### Scope state location

File at `$XDG_RUNTIME_DIR/claude-prompts/scope`.
Contents:
- `everywhere` — global view
- `<absolute path>` — project-scoped view
File is created by `scope.sh` if absent (default `everywhere`).
`query.sh` reads the file at every keystroke; no env threading required.

### Ingest offset

Stored in DB:
```sql
INSERT INTO ingest_state(key,value) VALUES ('byte_offset', ?)
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
```
Read with `SELECT value FROM ingest_state WHERE key='byte_offset';` (default 0 if missing).

---

## 4. Ingestion algorithm (precise)

**Trigger points:**
1. Every `popup.sh` launch (fast no-op when no new bytes).
2. Inside fzf via `Ctrl-R` → `execute-silent(ingest.sh --force)+reload(query.sh {q})`.

**Steps (`scripts/ingest.sh`):**

1. Resolve paths via `paths.sh`. Ensure DB directory exists; apply `schema.sql` (idempotent).
2. `current_offset = SELECT value FROM ingest_state WHERE key='byte_offset'` (default 0).
3. `file_size = stat -c %s $HISTORY_JSONL` (0 if missing → exit 0).
4. If `current_offset > file_size` → file was truncated/rotated. Reset `current_offset=0`.
5. If `current_offset == file_size` and `--force` not set → exit 0 (no work).
6. Open the file with `tail -c +$((current_offset + 1)) "$HISTORY_JSONL"` and pipe through `jq -c` that emits, per source line, **two stream types**:

   ```
   jq -c '
     select(.display != null and .display != "") |
     {
       kind: "prompt",
       display: .display,
       project: (.project // ""),
       ts: (.timestamp // 0),
       paste_keys: ((.pastedContents // {}) | keys)
     },
     ( (.pastedContents // {}) | to_entries[] |
       { kind: "paste",
         paste_id: (.key | tonumber),
         type: (.value.type // "text"),
         content: (.value.content // "") } )
   ' input.jsonl
   ```

   We feed this stream to a small bash reader that, per source-row, knows the prompt comes first and is followed by zero or more paste records. A line counter (or a synthesizing key in jq) groups them. Simpler approach: use `jq -c` with `input_line_number` to emit a `{"_line": N, ...}` envelope on every record; bash awks them into per-line groups.

   **Important:** previous research said to skip rows whose `display` matches `^\[Pasted text` — **reverse that decision**. A row whose display is `[Pasted text #1 +30 lines]` IS the prompt; the paste body is its substance. Keep all rows where `display != ""`. The empty-display skip remains.

7. For each prompt record:
   - `display_full = display` (preserved with newlines).
   - `display = gsub(\n, " ↵ ", display_full)`.
   - `hash = sha1sum(display_full + 0x1f + project)`.
   - Upsert into `prompts` with `RETURNING id`; capture `prompt_id`.
   - For each accompanying paste record, upsert into `paste_contents (prompt_id, paste_id, type, content)`.
   - Empty `pastedContents` object (the common case, ~95% of rows) → no paste rows written. The schema correctly handles this.

8. Buffer up to N=500 prompt records (with their paste fan-out) per transaction:
   ```
   BEGIN;
   <upsert prompt 1; capture id; upsert pastes for it>
   ...
   COMMIT;
   ```
   This avoids 12k subprocess fork-execs. For 12k rows / ~589 paste-bearing rows this is ~24 batches.

   Implementation note: SQLite's `RETURNING` requires reading sub-results between statements. Easiest in shell: write each prompt's `INSERT … RETURNING id` as a separate sqlite3 call inside the transaction file using a temp table (`CREATE TEMP TABLE last_id AS SELECT … RETURNING …`) — or use `last_insert_rowid()` after a non-conflicting insert. Cleanest: drive the loop in Python? No — stay shell-only. Use this pattern: insert prompts in batch with hash; then for each `(hash, paste_id, …)` triple, do `INSERT INTO paste_contents SELECT (SELECT id FROM prompts WHERE hash=?), ?, ?, ?`. This keeps it pure SQL. Document this in `ingest.sh`.

9. After the last batch, write new offset = `file_size`. Run `INSERT INTO prompts_fts(prompts_fts) VALUES ('optimize');` only on full re-ingest (offset was 0).
10. Exit 0. On any sqlite3 error, do not advance the offset (lets next run retry).

**Batched sql generation:** ingest.sh builds a temp file with all UPSERT statements then `sqlite3 "$DB" < tmpfile`. Use `printf '%s\n'` not `echo`. Quote literals via SQLite's `quote()` style with bash escaping helper `sql_quote()` that doubles single quotes.

**Performance targets:**
- Incremental, 0 new bytes: <30 ms (one stat, one sqlite query).
- Incremental, ~50 new lines: <100 ms.
- Full re-ingest, 12k lines: <2 s on the target machine. Critical: batched transactions, single `jq` subprocess, single `sha1sum` per line invoked from awk pipeline (or accept the per-row cost — measure).
- If sha1sum is the bottleneck, do hashing in awk via `length(display_full) || project` — but stick with sha1sum for correctness; profile first.

---

## 5. Query script contract

`scripts/query.sh "<query>"` — called by fzf on every keystroke change.

**Inputs:**
- `$1` = raw query string (may be empty)
- Reads scope from scope file
- Reads `ORIG_PATH` from env (set by `popup.sh`) — used only when scope is `everywhere` to compute "current project basename" for project chip display

**Output:** zero or more rows on stdout. Each row:

```
<id><US><ANSI-rendered-display-line>\n
```

where `<US>` is `\x1f` (single byte 0x1f, ASCII unit separator).

The ANSI-rendered display line has fixed structure:
```
<pin_glyph><sp><recency_glyph><sp><project_chip><sp><display_collapsed_truncated>
```
- `pin_glyph`: amber ★ if pinned, else single space (1 col always).
- `recency_glyph`: • if `now-ts < 1 day`, · if `< 7 days`, space otherwise (1 col).
- `project_chip`: 14-char left-padded basename of project + 2 trailing spaces (16 cols total). Dimmed ANSI (color 243). Empty (16 spaces) if project is empty or scope is project-scoped.
- `display_collapsed_truncated`: `display` column from DB (already collapsed). Truncated to fit; UI doc says "with … at end". `query.sh` does not truncate aggressively — it lets fzf clip and adds `…` only when the full string exceeds 500 chars (preview pane handles overflow anyway). **Paste markers `[Pasted text #N +M lines]` are kept as-is in the list view** — the size hint is information, and inline expansion would bloat rows. Preview pane does the resolution.

**ASCII fallback:** glyphs.sh sets `GLYPHS[pin_on]`, `GLYPHS[hot]`, `GLYPHS[warm]`, `GLYPHS[cold]`. query.sh references these.

**Algorithm:**
1. Read query `$Q`.
2. Read scope. If `everywhere`, `proj_filter=''`; else `proj_filter=<scope>`.
3. If `Q` is empty → run "browse" SQL (recent + pinned-first, LIMIT 500).
4. Else build FTS query: split on whitespace, drop bad chars (anything not alnum or `_-`), append `*` to each token, join with ` AND `. If after sanitization the query is empty (symbols-only) → set `fts_query=''`.
5. If `fts_query` non-empty → run FTS SQL. Capture row count.
6. If row count is 0 → run LIKE fallback SQL (`display LIKE '%' || ? || '%'`).
7. For each result, format as above and emit with `\x1f` separator.

**Final SQL queries** (parameters via sqlite3 `-cmd '.parameter set @q ...'` or via heredoc with quoted literals):

```sql
-- BROWSE (empty query)
SELECT id, display, project, ts, pinned
FROM prompts
WHERE (:proj = '' OR project = :proj)
ORDER BY pinned DESC, ts DESC
LIMIT 500;

-- FTS
SELECT p.id, p.display, p.project, p.ts, p.pinned
FROM prompts_fts f JOIN prompts p ON p.id = f.rowid
WHERE prompts_fts MATCH :q
  AND (:proj = '' OR p.project = :proj)
ORDER BY p.pinned DESC,
         (bm25(prompts_fts) - (CAST(:now AS REAL) - p.ts) / 2592000000.0) ASC
LIMIT 200;

-- LIKE fallback
SELECT id, display, project, ts, pinned
FROM prompts
WHERE display LIKE :like
  AND (:proj = '' OR project = :proj)
ORDER BY pinned DESC, ts DESC
LIMIT 200;
```

`:like` = `'%' || raw_query || '%'`. SQLite `LIKE` is ASCII-case-insensitive by default — sufficient.

---

## 6. fzf invocation (final)

Invoked from `popup.sh`. Path constants exported beforehand: `CP_BIN`, `CP_SCRIPTS`, `CP_DB`. We pick the **per-key `execute(...)+reload(...)` strategy** (not `--expect`) because actions like pin/scope must mutate state and refresh in place — `--expect` would force fzf to exit, then re-launch, losing cursor position.

```bash
fzf \
  --disabled \
  --ansi \
  --no-sort \
  --layout=reverse \
  --height=100% \
  --min-height=10 \
  --delimiter=$'\x1f' \
  --with-nth=2 \
  --prompt='  ' \
  --pointer='▶' \
  --marker='★' \
  --header="$("$CP_SCRIPTS/header.sh")" \
  --header-first \
  --preview="$CP_SCRIPTS/preview.sh {1}" \
  --preview-window='down:6:wrap' \
  --bind="start:reload:$CP_SCRIPTS/query.sh ''" \
  --bind="change:reload:$CP_SCRIPTS/query.sh {q}" \
  --bind="enter:execute-silent($CP_SCRIPTS/insert.sh paste {1})+abort" \
  --bind="ctrl-l:execute-silent($CP_SCRIPTS/insert.sh paste-literal {1})+abort" \
  --bind="ctrl-o:execute-silent($CP_SCRIPTS/insert.sh copy {1})+abort" \
  --bind="ctrl-p:execute-silent($CP_SCRIPTS/pin.sh {1})+reload($CP_SCRIPTS/query.sh {q})" \
  --bind="ctrl-s:execute-silent($CP_SCRIPTS/scope.sh toggle)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="ctrl-d:execute-silent($CP_SCRIPTS/delete.sh {1})+reload($CP_SCRIPTS/query.sh {q})" \
  --bind="ctrl-r:execute-silent($CP_SCRIPTS/ingest.sh --force)+reload($CP_SCRIPTS/query.sh {q})+transform-header($CP_SCRIPTS/header.sh)" \
  --bind="?:toggle-preview" \
  --bind="esc:abort"
```

Notes:
- `transform-header` (fzf 0.44+) re-runs the header script after scope/ingest changes — correct in our environment.
- `?` reuses the preview pane as a help overlay. `preview.sh` checks an env-var sentinel; cleanest is to have a separate `help-preview` toggle bind. **Decision:** keep `?` as `toggle-preview` (UI doc accepts that), and make help an explicit `--header` line. Don't overengineer the help overlay in v1; document `?` as "show/hide preview" for now and revisit.
- All `{1}` references resolve to the id (first \x1f-delimited field).

---

## 7. Send-to-pane flow

**Decision:** action runs *inside* the popup via fzf `execute-silent`. `popup.sh` does not do post-processing on stdout. The popup closes naturally via fzf `abort` and tmux `-E`.

`scripts/insert.sh <action> <id>` where `<action>` is `paste`, `paste-literal`, or `copy`:

1. Look up `display_full` for `<id>` from DB.
2. **Resolve markers** unless `<action>` is `paste-literal`:
   - Pipe `display_full` through `scripts/resolve.sh <id>` which scans for `\[Pasted text #([0-9]+)( \+[0-9]+ lines)?\]` and replaces each marker with the matching `paste_contents.content` (looked up by `prompt_id=<id>` and `paste_id=$1`).
   - If a marker has no matching paste row (data anomaly), leave it untouched.
   - `paste-literal` skips this step — the raw `display_full` (with markers) is what gets inserted.
3. If `paste` or `paste-literal`:
   - If `$ORIG_PANE` set and `$TMUX` set: `tmux set-buffer -- "$text"; tmux paste-buffer -p -d -t "$ORIG_PANE"` (`-d` deletes the buffer after paste — keeps the buffer ring clean).
   - Else: fall through to clipboard.
4. If `copy` (always sends resolved text — copying the literal markers would be useless) or paste-fallback:
   - WSL detection: `[ -n "$WSL_DISTRO_NAME" ] && command -v clip.exe` → `clip.exe`.
   - Else priority: `wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`, `pbcopy`.
   - If none available: print "no clipboard tool" to stderr, exit 1.
5. Exit 0.

### `scripts/resolve.sh <id>` — marker expansion

Reads `display_full` for `<id>` from DB, then for each marker `[Pasted text #N +M lines]` in the text, fetches `SELECT content FROM paste_contents WHERE prompt_id=<id> AND paste_id=N` and substitutes inline. Implemented as a single awk pass that pre-loads all paste rows for the prompt into an associative array and replaces with `gsub`. Output: resolved text on stdout.

Marker regex (extended POSIX): `\[Pasted text #([0-9]+)( \+[0-9]+ lines)?\]` — the trailing ` +M lines` group is optional (older entries may omit it).

### `scripts/preview.sh <id>` — preview rendering

Differs from `resolve.sh`: instead of replacing markers with raw content, it renders each paste as a fenced block so the user can visually distinguish prompt prose from inlined paste body. Format:

```
<prefix display text up to marker>
─── pasted #1 (text, 30 lines) ───
<full paste content>
───────────────────────────────────
<rest of display>

────────────────────────────────────────
<project basename> · <relative-time> · <line-count> lines · <paste-count> pastes
```

The fence character is U+2500 (`─`); ASCII fallback uses `-`. Width follows preview-pane width (read from `$FZF_PREVIEW_COLUMNS` if available, else 80). Body text is wrapped at column width via `fold -s -w "$cols"`.

### Keymap (final, after Ctrl-L addition)

| Key | Action |
|---|---|
| `Enter` | Insert **resolved** prompt (markers expanded) into originating pane |
| `Ctrl-L` | Insert **literal** display (markers unresolved) — escape hatch for editing |
| `Ctrl-O` | Copy resolved prompt to clipboard |
| `Ctrl-P` | Toggle pin on selected row |
| `Ctrl-S` | Toggle scope (Everywhere ↔ Project) |
| `Ctrl-D` | Delete row from local store (recoverable via Ctrl-R) |
| `Ctrl-R` | Force re-ingest from history.jsonl |
| `?`     | Toggle preview pane |
| `Esc`   | Close popup |

Footer hint string (the trailing `--header` line):
```
  enter insert  ^l literal  ^p pin  ^s scope  ^o copy  esc close
```

`ORIG_PANE` is captured at bind-time via `#{pane_id}` (see §8) and passed into the popup environment via `display-popup -e "ORIG_PANE=$ORIG_PANE"`.

---

## 8. tmux keybind registration

### `claude-prompts.tmux` (TPM entrypoint, executable)

```bash
#!/usr/bin/env bash
set -eu
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"
# shellcheck source=scripts/helpers.sh
. "$SCRIPTS_DIR/helpers.sh"

key=$(get_option "@claude_prompts_key" "M-p")
table=$(get_option "@claude_prompts_key_table" "root")
prefix_key=$(get_option "@claude_prompts_prefix_key" "")

# Primary binding (root by default → no prefix)
if [ "$table" = "root" ]; then
  tmux bind-key -n "$key" run-shell "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}'"
else
  tmux bind-key -T "$table" "$key" run-shell "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}'"
fi

# Optional secondary binding under prefix
if [ -n "$prefix_key" ]; then
  tmux bind-key "$prefix_key" run-shell "'$SCRIPTS_DIR/launch.sh' '#{pane_id}' '#{pane_current_path}'"
fi
```

### `scripts/launch.sh`

```bash
#!/usr/bin/env bash
set -eu
ORIG_PANE="${1:-}"
ORIG_PATH="${2:-$HOME}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE=$(tmux show-option -gqv "@claude_prompts_popup_size")
SIZE="${SIZE:-90%}"

tmux display-popup \
  -E \
  -w "$SIZE" -h "$SIZE" \
  -b rounded \
  -T " Claude Prompts " \
  -d "$ORIG_PATH" \
  -e "ORIG_PANE=$ORIG_PANE" \
  -e "ORIG_PATH=$ORIG_PATH" \
  -e "CP_ROOT=$CURRENT_DIR" \
  "$CURRENT_DIR/scripts/popup.sh"
```

### Configuration variables (read from tmux options)

| Option | Default | Purpose |
|---|---|---|
| `@claude_prompts_key` | `M-p` | Primary key. |
| `@claude_prompts_key_table` | `root` | `root` or `prefix`. |
| `@claude_prompts_prefix_key` | (empty) | Optional secondary prefix-key. Empty = disabled. |
| `@claude_prompts_popup_size` | `90%` | Width and height (single value used for both). |
| `@claude_prompts_no_nerd` | (empty) | If `1`, force ASCII glyphs. |

Also honored as env vars (for standalone mode): `CLAUDE_PROMPTS_NO_NERD=1`.

---

## 9. Test plan (bats-core)

### `tests/fixtures/history.jsonl` — 9 lines

```
{"display":"/init what should the schema look like","project":"/opt/development/tmux-claude-prompts","timestamp":1714780000000,"pastedContents":{}}
{"display":"/init what should the schema look like","project":"/opt/development/tmux-claude-prompts","timestamp":1714780500000,"pastedContents":{}}
{"display":"Fix the auth middleware so tokens refresh before expiry","project":"/opt/development/api-service","timestamp":1714770000000,"pastedContents":{}}
{"display":"[Pasted text #1 +3 lines]","project":"/opt/development/api-service","timestamp":1714760000000,"pastedContents":{"1":{"id":1,"type":"text","content":"def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew"}}}
{"display":"","project":"/opt/development/api-service","timestamp":1714750000000,"pastedContents":{}}
{"display":"Update zsh aliases\nAlso check brew shellenv\nRun shellcheck on .zshrc","project":"/home/joedegler/dotfiles","timestamp":1714740000000,"pastedContents":{}}
{"display":"profile cloudflare workers cold start","project":"/opt/development/playbook-cloudflare-workers","timestamp":1714730000000,"pastedContents":{}}
{"display":"Profile Cloudflare Workers Cold Start","project":"/opt/development/playbook","timestamp":1714720000000,"pastedContents":{}}
{"display":"Look at this:\n[Pasted text #1 +5 lines]\nand also [Pasted text #2 +2 lines]","project":"/opt/development/playbook","timestamp":1714710000000,"pastedContents":{"1":{"id":1,"type":"text","content":"line a\nline b\nline c\nline d\nline e"},"2":{"id":2,"type":"text","content":"err: ENOENT\nerr: ETIMEDOUT"}}}
```

Edge cases covered:
(a) duplicate (display, project) at different ts → dedup, max ts kept;
(b) **paste-marker-only display + paste contents → kept as a row, paste indexed**;
(c) empty display → skipped;
(d) multi-line display → newline collapse;
(e) same prose across different projects → kept as two rows;
(f) case-insensitive match across the two `Profile Cloudflare` rows;
(g) **mixed prompt with multiple inline paste markers**;
(h) **pastedContents empty object** (the common case).

### `tests/helpers.bash`

```bash
#!/usr/bin/env bash
load_fixtures() {
  export TEST_TMP="$(mktemp -d)"
  export XDG_DATA_HOME="$TEST_TMP/data"
  export XDG_RUNTIME_DIR="$TEST_TMP/run"
  export HOME_BACKUP="$HOME"
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
  cp "$BATS_TEST_DIRNAME/fixtures/history.jsonl" "$HOME/.claude/history.jsonl"
}
teardown_fixtures() {
  rm -rf "$TEST_TMP"
  export HOME="$HOME_BACKUP"
}
```

### `tests/ingest.bats` — cases

1. `ingests fresh fixture`: after `ingest.sh`, `SELECT count(*) FROM prompts` returns **7** (9 input lines − 1 empty − 1 dup; paste-only rows now KEPT).
2. `is idempotent on second run`: run twice; row count unchanged; `byte_offset` advanced once.
3. `skips empty display only` (NOT paste markers): the `[Pasted text #1 +3 lines]` row IS present in `prompts`.
4. `ingests paste contents into paste_contents table`: `SELECT count(*) FROM paste_contents` returns **3** (one for the api-service paste, two for the multi-paste playbook row).
5. `keeps max(ts) on duplicate`: the `/init` row has `ts == 1714780500000`.
6. `collapses newlines into ↵ marker`: the dotfiles row's `display` contains `↵` and no raw `\n`.
7. `incremental ingest picks up new lines`: append a 10th line; offset detection picks only that line.
8. `paste contents survive re-ingest`: run `ingest.sh --force` twice; `paste_contents` row count is stable.

### `tests/query.bats` — cases

1. `empty query returns recent first`: `query.sh ''` first non-pinned row is the `1714780500000` `/init` row.
2. `case-insensitive match`: `query.sh "cloudflare"` returns both `profile cloudflare` rows.
3. `prefix tokens match`: `query.sh "cloud"` matches `cloudflare` rows via FTS prefix.
4. `fallback LIKE engaged for symbol-only query`: `query.sh "/"` — FTS empty after sanitization → LIKE fallback returns the `/init` row.
5. `scope=project filters by project`: write `/opt/development/api-service` to scope file, `query.sh ''` → only api-service rows.
6. `pinned rows sort first`: pin a low-ts row, empty query puts it on top.
7. **`FTS finds prompt by paste content`**: `query.sh "ENOENT"` returns the multi-paste playbook row (only matches via paste content, not display).
8. **`FTS finds prompt by paste content with prefix`**: `query.sh "refresh"` returns the api-service paste-only row (matches `refresh_token` inside paste content).

### `tests/pin.bats` — cases

1. `toggles pinned column on first call`: row 1 pinned=0 → pin → pinned=1, pinned_at NOT NULL.
2. `toggles back on second call`: pinned=1 → unpin → pinned=0, pinned_at NULL.
3. `pinned rows sort before unpinned in browse query`: confirmed via `query.sh ''`.
4. `preserves pin across re-ingest`: pin row → run `ingest.sh --force` → pin still set.
5. `non-existent id is a no-op`: `pin.sh 99999` exits 0, prompts table unchanged.

### `tests/insert.bats` — new file, cases

1. `marker replacement produces full text`: for the api-service paste-only row, `resolve.sh <id>` outputs `def refresh_token():\n    raise NotImplementedError\n# TODO: handle clock skew` (no markers remain).
2. `multiple markers replaced in one prompt`: for the playbook multi-paste row, both `#1` and `#2` markers are replaced; output contains `line a` and `ENOENT` and the prose `Look at this:` and `and also`.
3. `literal mode preserves markers`: `insert.sh paste-literal <id>` (with `ORIG_PANE` mocked) sends text containing the literal `[Pasted text #1 +3 lines]` substring.
4. `paste action with no paste rows is identity`: for a row with empty `pastedContents`, `resolve.sh` output equals `display_full` exactly.
5. `unmatched marker is left untouched`: synthesize a row whose display has `[Pasted text #99 +0 lines]` but no matching paste row — `resolve.sh` leaves it intact.
6. `tmux paste invokes set-buffer + paste-buffer -p -d`: with a stub `tmux` shim that logs argv, verify the exact invocation including the `-d` flag and `$ORIG_PANE` target.

---

## 10. Build/install instructions (for README)

### Install (manual / dev)

```bash
mkdir -p ~/.tmux/plugins
ln -sf /opt/development/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
chmod +x /opt/development/tmux-claude-prompts/claude-prompts.tmux
```

Add to `~/.tmux.conf`:
```tmux
run-shell ~/.tmux/plugins/tmux-claude-prompts/claude-prompts.tmux
```

Reload: `tmux source ~/.tmux.conf`.

### Install (TPM)

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin '<user>/tmux-claude-prompts'
run '~/.tmux/plugins/tpm/tpm'
```

### First use

Press `Alt+P` (default). First popup invocation triggers full ingest (~2 s on 12k rows). Subsequent opens are instant.

### Standalone use

```bash
/opt/development/tmux-claude-prompts/bin/claude-prompts open
```
Outside tmux: Enter copies to clipboard (no paste). Useful from a regular shell.

### Dependencies (checked at startup)

`tmux ≥ 3.2`, `bash ≥ 4.4`, `sqlite3 ≥ 3.9` (with FTS5), `fzf ≥ 0.44`, `jq ≥ 1.6`, `sha1sum`. Optional: `clip.exe`/`wl-copy`/`xclip`/`pbcopy` for clipboard fallback.

---

## 11. Build sequence for implementation agents

Each batch runs to completion before the next starts. Within a batch, items are independent unless noted.

### Batch A — Foundation (parallel-safe)

| File | Inputs | Outputs | Exit codes | Acceptance test |
|---|---|---|---|---|
| `scripts/paths.sh` | env (`HOME`, `XDG_*`) | exported vars: `CP_DB`, `CP_SCOPE_FILE`, `CP_HISTORY`, `CP_DATA_DIR`, `CP_RUN_DIR` | n/a (sourced) | `bash -c '. paths.sh; [ -n "$CP_DB" ]'` succeeds. |
| `scripts/glyphs.sh` | env `CLAUDE_PROMPTS_NO_NERD`, `@claude_prompts_no_nerd` (via `get_option` if tmux up), `TERM` | `declare -A GLYPHS` populated with all keys: `pin_on`, `pin_off`, `hot`, `warm`, `cold`, `proj`, `globe`, `nl`, `trunc`, `ret` | n/a (sourced) | `bash -c '. glyphs.sh; echo "${GLYPHS[pin_on]}"'` prints ★ (or `*` under NO_NERD=1). |
| `scripts/helpers.sh` | tmux (optional) | functions: `get_option`, `require_dep`, `sql`, `sql_quote`, `now_ms`, `is_tmux` | n/a (sourced) | `bash -c '. helpers.sh; require_dep sqlite3'` exits 0 on a system with sqlite3. |
| `scripts/schema.sql` | n/a | DDL file | n/a | `sqlite3 :memory: < schema.sql` exits 0. |
| `scripts/ingest.sh` | `$CP_HISTORY`, optional `--force` | populated DB | 0 success; 1 dep missing; 2 sql error | After running on fixture, `sqlite3 $CP_DB 'SELECT count(*) FROM prompts;'` returns 5. |
| `tests/fixtures/history.jsonl` | n/a | static fixture | n/a | File parses as valid JSONL (`jq -e . < fixture` exits 0 per line). |
| `tests/helpers.bash` | bats env | sourced helpers | n/a | `bats tests/ingest.bats` (after batch A completes) is bootstrappable. |

### Batch B — Search & state (depends on Batch A)

| File | Inputs | Outputs | Exit codes | Acceptance test |
|---|---|---|---|---|
| `scripts/query.sh` | `$1` (query), scope file, env `ORIG_PATH` | rows on stdout, `<id>\x1f<rendered>` | 0 always (empty stdout = no matches) | `query.sh "init"` after fixture ingest emits ≥1 row containing the id and the rendered display. |
| `scripts/pin.sh` | `$1` (id) | DB mutation | 0 success; 1 invalid id | `pin.sh 1` toggles `pinned` on row 1 in fixture-DB. |
| `scripts/scope.sh` | `$1` ∈ `{toggle, get, set <path>}`; `$ORIG_PATH` | scope file write | 0 | `scope.sh toggle` flips file content between `everywhere` and `$ORIG_PATH`. |
| `scripts/delete.sh` | `$1` (id) | DB mutation | 0 | `delete.sh 1` removes row 1 from prompts; FTS row also gone via trigger. |
| `scripts/preview.sh` | `$1` (id) | rendered preview text on stdout | 0 | `preview.sh 1` prints the row's `display_full` with paste markers expanded inline as fenced blocks (see §7a), plus a trailing metadata line (`<project> · <relative-time> · <line-count> lines · <paste-count> pastes`). |
| `scripts/resolve.sh` | `$1` (id) | resolved text on stdout | 0 | For an id whose display contains `[Pasted text #1 +30 lines]`, output replaces the marker with `paste_contents.content` for paste_id=1. Idempotent on rows with no paste rows. |
| `scripts/header.sh` | scope file, db | one or two header lines on stdout | 0 | Renders `Claude Prompts   [Everywhere]   <count>` plus footer hint line. |

### Batch C — UI & integration (depends on Batches A, B)

| File | Inputs | Outputs | Exit codes | Acceptance test |
|---|---|---|---|---|
| `scripts/insert.sh` | `$1` ∈ `{paste, copy}`; `$2` (id); env `ORIG_PANE` | tmux paste-buffer or clipboard call | 0 success; 1 no clipboard | Stub-tested: `insert.sh copy 1` populates the system clipboard (manual smoke); `insert.sh paste 1` calls `tmux set-buffer/paste-buffer` with correct args (verifiable via mock-tmux wrapper in tests). |
| `scripts/popup.sh` | env `ORIG_PANE`, `ORIG_PATH`, `CP_ROOT` | runs ingest then fzf | fzf exit code | Smoke: launching the popup from a tmux session shows the prompt list within 200 ms; Enter pastes into the originating pane. |
| `scripts/launch.sh` | `$1` pane id, `$2` pane path | tmux display-popup invocation | 0 | `launch.sh %3 /tmp` invokes display-popup with correct `-e` vars (verifiable in dry-run mode that prints the would-be command). |
| `claude-prompts.tmux` | tmux user options | tmux bind-key calls | 0 | `tmux source claude-prompts.tmux` registers the binding; `tmux list-keys -T root M-p` shows it. |
| `bin/claude-prompts` | argv | dispatches to scripts | varies | `bin/claude-prompts open` runs popup-or-standalone correctly. Subcommands: `open`, `ingest`, `pin <id>`, `scope <toggle|get|set>`, `query <q>`, `insert <paste|copy> <id>`, `version`. |

### Batch D — Tests + docs (depends on all)

| File | Acceptance |
|---|---|
| `tests/ingest.bats` | All 8 cases from §9 pass under `bats tests/ingest.bats`. |
| `tests/query.bats` | All 8 cases pass (incl. paste-content matches). |
| `tests/pin.bats` | All 5 cases pass. |
| `tests/insert.bats` | All 6 cases pass (marker resolution + literal mode + tmux invocation shape). |
| `README.md` | Sections: Why, Install (TPM + manual), Keys (incl. Ctrl-L literal-insert), Configuration, Standalone usage, Pasted-content handling (a brief callout), Architecture overview (one paragraph), Troubleshooting, Tests. |

---

## 12. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `jq`, `sqlite3`, or `fzf` missing | `helpers.sh::require_dep` checks at every script entry. `ingest.sh` and `popup.sh` print a friendly one-line error to stderr (and into the popup as a fallback fzf list with one row "missing dep: …") and exit 1. |
| SQLite without FTS5 | First-run ingest tries `CREATE VIRTUAL TABLE … USING fts5(...)`. On error: print "your sqlite was built without FTS5; install `sqlite3` package or rebuild with `-DSQLITE_ENABLE_FTS5`" and exit 2. |
| Concurrent popups | `PRAGMA journal_mode=WAL` + `PRAGMA busy_timeout=3000` in schema. Multiple readers + one writer is safe. Pin/delete writes are millisecond-scale; collisions tolerable. |
| Very long prompts (>10 KB) | DB stores full `display_full` (no truncation). `query.sh` truncates the rendered list line to 500 chars max + `…`. Preview pane shows the full text. Tested with a single 50-KB row — fzf rendering and SQLite both fine. |
| Pane-id capture race | `#{pane_id}` is captured by tmux at the moment the keybind fires (inside `run-shell` argument), before `display-popup` opens. Stored in `$1` of `launch.sh`, then propagated as `-e ORIG_PANE=$ORIG_PANE`. Inside the popup `$TMUX_PANE` is *not* used. |
| `XDG_RUNTIME_DIR` unset (rare in popup envs) | `paths.sh` falls back to `/tmp/claude-prompts-$USER` and creates dir with mode 0700. |
| `pane_current_path` differs from real CWD | Acceptable — UI doc accepts shell-CWD-at-last-prompt as "current project". |
| `history.jsonl` rotated/truncated | `ingest.sh` detects `current_offset > file_size` and resets to 0; full re-ingest follows. Idempotent because hashes are stable. |
| User deletes by accident with `Ctrl-D` | `Ctrl-R` re-ingests from source jsonl, restoring the row (since source was untouched). Document in README under "undo". |
| fzf < 0.44 (no `transform-header`) | `helpers.sh::require_dep` checks fzf version on launch. If too old, omit the `transform-header` action and rely on a one-line static header (degraded UX, still functional). |
| Standalone (no tmux) launches | `bin/claude-prompts open` detects `[ -z "$TMUX" ]` and runs the fzf loop directly in the current terminal; insert→clipboard fallback. |
| `clip.exe` returns CRLF in WSL | `printf '%s'` (no trailing newline) when piping to `clip.exe`. |
| Hash collision sha1 of arbitrary text | Negligible (10⁻⁴⁰ for our scale). Not handled. |
| Very large paste content (multi-MB) | DB stores full content. FTS5 contentless mode duplicates it once. At ~5% of rows × avg 5 KB observed, total overhead ~3 MB — acceptable. If a single paste exceeds 1 MB, the FTS5 row insert is fine (no hard limit). Preview pane truncates rendered output at 500 lines per paste with a `... (truncated, N more lines)` marker — implemented in `preview.sh`. |
| Paste marker without matching `pastedContents` entry | Possible in malformed entries. `resolve.sh` leaves the marker in place (visible to user). Tested in `insert.bats` case 5. |
| Marker regex false positive in user prose (e.g. `[Pasted text #1]` written by hand) | Tolerable — replacement only happens if a matching paste row exists; otherwise the text stays as written. |
| `sqlite3` CLI argument-length limit on bulk insert | We use a temp file fed via stdin (`sqlite3 $DB < file`), not argv — limit is irrelevant. |

---

## Appendix A — Final glyph table (mirrored from UI doc)

| Key | Nerd | ASCII | Color |
|---|---|---|---|
| `pin_on` | ★ | * | color 214 (amber) |
| `pin_off` | (space) | (space) | — |
| `hot` (<1d) | • | . | color 244 |
| `warm` (<7d) | · | , | color 244 |
| `cold` (≥7d) | (space) | (space) | — |
| `proj` |  | > | color 243 |
| `globe` |  | @ | color 81 (cyan) |
| `nl` (in-text) | ↵ | \n | color 244 |
| `trunc` | … | ... | — |

Selection rule: Nerd Font glyphs by default; `CLAUDE_PROMPTS_NO_NERD=1` (env or `@claude_prompts_no_nerd 1`) forces ASCII column.

## Appendix B — Subcommand surface for `bin/claude-prompts`

```
claude-prompts open                       # launch popup if in tmux, else standalone fzf
claude-prompts ingest [--force]            # incremental (or forced full) re-ingest
claude-prompts pin <id>                    # toggle pin
claude-prompts scope <toggle|get|set <path>>
claude-prompts query <q>                   # emit raw fzf rows (debugging aid)
claude-prompts insert <paste|copy> <id>    # apply action (debugging / scripting)
claude-prompts version
```

The dispatcher is a thin shim: each subcommand `exec`s the corresponding `scripts/*.sh` so behavior is identical.
