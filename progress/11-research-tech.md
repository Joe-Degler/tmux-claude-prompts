# Tech Research: Claude Prompt Browser — Stack Decisions

**Date:** 2026-05-04  
**Status:** Final — ready for P2 planning

---

## Final Stack

| Layer | Choice | One-line justification |
|---|---|---|
| Storage | SQLite 3.45 + FTS5 | Incremental ingest, ranked search, persistent pins, zero extra deps beyond `sqlite3` CLI |
| Search | FTS5 MATCH + LIKE fallback | Handles word-prefix, ranked results via bm25, graceful fallback for single-char/CJK |
| TUI | fzf 0.44 (`--disabled` mode) | Live SQL-driven reload per keystroke; proven pattern; available via apt on target system |
| Shell | bash 5 | Already mandatory for tmux plugin ecosystem; bats tests work natively |
| Tests | bats-core | Standard bash test runner; fixture-based; covers ingestion, search, pin, scope |

---

## Data Sample Findings

Sampled offsets 0–29, 2000–2029, 4990–5009, 6000–6029, 9000–9029, 11880–11920.

### Key observations

**Slash-command duplicates are the dominant noise.** At offsets 5–8, `/compact` appears four consecutive times with timestamps 1 ms apart (same ms in some cases). At offsets 16–21, `/export` ×3 and `/cost` ×3 appear within milliseconds. This pattern recurs throughout. These represent Claude Code emitting the same entry multiple times per invocation (likely one per hook/session fan-out).

**`display` content types observed:**
- Slash commands: `/init`, `/compact`, `/export`, `/cost`, `/clear`, `/resume`, `/ide`, `/model`, `/effort`, `/chrome`, `/btw`, `/local-review:local-review`, `/sentry-skills:code-review` — all short, frequently repeated
- Short imperatives: "Resume", "Sorry, keep going", "Try again", "Commit.", "stop"
- Multi-sentence prose: profiling requests, architectural questions, feature specs — up to 10+ lines
- Paste-marker entries: `"[Pasted text #1 +107 lines]"` where `display` is just the label and real content is in `pastedContents` (sometimes with `contentHash` only — content stripped)
- Mixed: prose with inline paste reference, e.g. `"hmm... this works, why?\n\n[Pasted text #1 +21 lines]"`

**Newlines in `display`:** Yes, confirmed. Entries like the profiling request at offset 9 contain `\n`-encoded newlines within the JSON string. fzf renders each line as a row, so we must collapse `\n` → space (or `↵`) in the list view. The full text is shown in the preview pane.

**`project` diversity:** `/opt/development/playbook` is dominant. Also seen: `/opt/development/backblaze-proxy`, `/opt/development/clooks`, `/opt/development/resumable-uploads-proxy`, `/opt/development/video-processor-gpu`, `/opt/development/playbook-cloudflare-workers`, `/opt/development/optivolt-platform`, `/home/joedegler`, `/home/joedegler/IdeaProjects/s3-client`, `/opt/development/tmux-claude-prompts`. About 10–15 distinct projects across the full file.

**`sessionId` field:** Present on newer entries (offset 2000+), absent on oldest entries (offset 0–30). Not in the originally documented schema — treat as optional bonus field.

**Empty `display`:** Not observed in samples, but paste-only entries like `"[Pasted text #2 +21 lines]"` are semantically empty for search purposes. We should skip entries where `display` matches `^\[Pasted text` or is blank.

**Deduplication verdict:** Collapse on `(display, project)` keeping `max(ts)`. Rationale: slash commands repeated 3–4× in sequence are useless duplicates; the same prose prompt reused across projects is genuinely different (different context). This collapses ~30–40% of the dataset estimated, leaving a cleaner result set.

---

## 1. Storage Decision: SQLite + FTS5

**Option A (raw jsonl + jq):** Scanning 4 MB / 12k lines with jq on every keystroke is ~200–400 ms — unusable for live search. Even on open it would be perceptible (>100 ms). Rejected.

**Option B (SQLite with FTS5):** Chosen. sqlite3 3.45.1 is available via apt (`apt-cache show sqlite3` confirms). FTS5 has been bundled by default since SQLite 3.9 (2015); Ubuntu's build includes it. Queries on 12k rows return in <5 ms. Persistent `pinned` column lives in the same DB. Incremental ingest via byte-offset tracking keeps re-runs cheap.

### SQLite Schema (DDL)

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS prompts (
  id        INTEGER PRIMARY KEY,
  display   TEXT    NOT NULL,
  project   TEXT    NOT NULL DEFAULT '',
  ts        INTEGER NOT NULL,          -- max(timestamp) ms epoch for this (display, project) group
  pinned    INTEGER NOT NULL DEFAULT 0,
  pinned_at INTEGER,                   -- ms epoch when pinned, NULL if not pinned
  hash      TEXT    UNIQUE NOT NULL    -- sha1(display || '|' || project) for dedup
);

CREATE TABLE IF NOT EXISTS ingest_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- key='byte_offset' value='<integer>'

CREATE VIRTUAL TABLE IF NOT EXISTS prompts_fts
  USING fts5(
    display,
    content='prompts',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
  );

-- Keep FTS in sync via triggers
CREATE TRIGGER IF NOT EXISTS prompts_ai AFTER INSERT ON prompts BEGIN
  INSERT INTO prompts_fts(rowid, display) VALUES (new.id, new.display);
END;

CREATE TRIGGER IF NOT EXISTS prompts_ad AFTER DELETE ON prompts BEGIN
  INSERT INTO prompts_fts(prompts_fts, rowid, display)
    VALUES ('delete', old.id, old.display);
END;

CREATE TRIGGER IF NOT EXISTS prompts_au AFTER UPDATE ON prompts BEGIN
  INSERT INTO prompts_fts(prompts_fts, rowid, display)
    VALUES ('delete', old.id, old.display);
  INSERT INTO prompts_fts(rowid, display) VALUES (new.id, new.display);
END;

CREATE INDEX IF NOT EXISTS idx_prompts_project ON prompts(project);
CREATE INDEX IF NOT EXISTS idx_prompts_ts      ON prompts(ts DESC);
CREATE INDEX IF NOT EXISTS idx_prompts_pinned  ON prompts(pinned DESC, ts DESC);
```

DB location: `~/.local/share/claude-prompts/db.sqlite` (XDG-compliant).

---

## 2. Ingestion Algorithm

### Pseudocode

```
DB = open_or_create(~/.local/share/claude-prompts/db.sqlite)
apply_schema(DB)

offset = DB.query_scalar("SELECT value FROM ingest_state WHERE key='byte_offset'") || 0
fd = open(~/.claude/history.jsonl)
seek(fd, offset)

new_lines = 0
while line = readline(fd):
  if line is blank: continue

  display  = jq '.display'   from line
  project  = jq '.project'   from line  (default '')
  ts       = jq '.timestamp' from line

  # Skip paste-only or empty entries
  if display is empty or display matches ^\[Pasted text: continue

  # Collapse newlines for storage (store collapsed; original reconstructable if needed)
  display_clean = gsub('\n', ' ', display)

  hash = sha1sum(display_clean + '|' + project)

  DB.execute("""
    INSERT INTO prompts (display, project, ts, hash)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(hash) DO UPDATE SET ts = MAX(ts, excluded.ts)
  """, display_clean, project, ts, hash)

  new_lines++

new_offset = tell(fd)
DB.execute("INSERT OR REPLACE INTO ingest_state VALUES ('byte_offset', ?)", new_offset)
DB.execute("COMMIT")
```

**sha1sum call:** `printf '%s' "${display}|${project}" | sha1sum | cut -c1-40`

**Re-ingest safety:** `ON CONFLICT(hash) DO UPDATE SET ts = MAX(ts, excluded.ts)` means running twice is idempotent. New lines at end of file are appended cheaply. Full re-ingest (offset=0) is safe and produces same result — useful for schema migrations.

**FTS rebuild after bulk ingest:** After inserting many rows, run:
```sql
INSERT INTO prompts_fts(prompts_fts) VALUES ('optimize');
```

**Performance:** At 12k lines / 4 MB, full initial ingest takes ~2–4 seconds (dominated by sha1sum subprocess per line). Optimization: batch with `jq -c` streaming all fields at once, one subprocess for the whole file. On re-runs only new bytes are processed — typically <100 ms.

---

## 3. Search Query

### Query construction (bash → SQL)

```bash
# $1 = raw user query string, $2 = project filter or '' for Everywhere

build_fts_query() {
  local q="$1"
  # split on whitespace, suffix each token with * for prefix match, join with AND
  echo "$q" | tr ' ' '\n' | grep -v '^$' | sed 's/$/*/; s/ //g' | paste -sd' ' | \
    sed 's/  */ AND /g'
  # e.g. "profile cloudflare" → "profile* AND cloudflare*"
}
```

### Final SQL (with placeholders)

**Non-empty query, no project filter:**
```sql
SELECT p.id, p.display, p.project, p.ts, p.pinned
FROM prompts_fts f
JOIN prompts p ON p.id = f.rowid
WHERE prompts_fts MATCH ?          -- fts_query e.g. 'profile* AND cloudflare*'
ORDER BY
  p.pinned DESC,
  (bm25(prompts_fts) - (CAST(? AS REAL) - p.ts) / 2592000000.0) ASC
  -- decay: 30 days in ms = 2,592,000,000. Lower bm25 = better match.
  -- recency bonus: subtract up to ~1.0 for entries within last 30 days
LIMIT 200;
```

**Non-empty query, project-scoped:**
```sql
-- same as above but add: AND p.project = ?
```

**Fallback (FTS returns 0 rows — handles single chars, symbols, CJK):**
```sql
SELECT id, display, project, ts, pinned
FROM prompts
WHERE display LIKE ? -- '%' || query || '%', case-insensitive (SQLite default for ASCII)
  AND (? = '' OR project = ?)
ORDER BY pinned DESC, ts DESC
LIMIT 200;
```

**Empty query (browse mode):**
```sql
SELECT id, display, project, ts, pinned
FROM prompts
WHERE (? = '' OR project = ?)
ORDER BY pinned DESC, ts DESC
LIMIT 500;
```

**Decay constant rationale:** 30 days (2,592,000,000 ms). bm25 scores typically range -1.0 to -10.0 (more negative = better). Recency bonus of up to 1.0 for very recent entries is meaningful without overwhelming relevance for strong term matches.

---

## 4. TUI: fzf with `--disabled` mode

**Comparison:**

| Option | Pro | Con | Verdict |
|---|---|---|---|
| fzf `--disabled` + `--reload` | Proven pattern, live SQL results per keystroke, rich keybinds, preview pane, widely installed | Requires fzf ≥ 0.27 | **Chosen** |
| gum filter | Prettier defaults | No live-reload, filtering is client-side only, no keybind extensibility | Rejected |
| custom Bash + ANSI | Full control | ~500 lines of TUI plumbing, reinventing fzf UX | Rejected |
| skim (sk) | fzf-compatible | Not installed by default, smaller community, no advantage here | Rejected |

fzf 0.44.1 is available via apt on this Ubuntu system. `--disabled` disables fzf's own fuzzy matching so every keystroke delegates to our SQL query script. `change:reload` fires on every input change.

### fzf Invocation (canonical command line)

```bash
SCOPE_FILE="${XDG_RUNTIME_DIR:-/tmp}/claude-prompts.scope"
# scope file contains either '' (everywhere) or an absolute project path

fzf \
  --disabled \
  --ansi \
  --prompt '  ' \
  --pointer '▶' \
  --marker '★' \
  --header $'ctrl-p: pin/unpin  ctrl-s: scope  ctrl-y: copy  enter: insert\n' \
  --header-first \
  --layout reverse \
  --height '100%' \
  --min-height 10 \
  --preview 'echo {4}' \
  --preview-window 'down:4:wrap:hidden' \
  --bind 'change:reload(bash /opt/development/tmux-claude-prompts/bin/query.sh {q})' \
  --bind 'ctrl-p:execute-silent(bash /opt/development/tmux-claude-prompts/bin/pin.sh {1})+reload(bash /opt/development/tmux-claude-prompts/bin/query.sh {q})' \
  --bind 'ctrl-s:execute-silent(bash /opt/development/tmux-claude-prompts/bin/toggle-scope.sh)+reload(bash /opt/development/tmux-claude-prompts/bin/query.sh {q})' \
  --bind 'ctrl-y:execute-silent(echo {4} | xclip -selection clipboard)' \
  --bind 'ctrl-/:toggle-preview' \
  --bind 'start:reload(bash /opt/development/tmux-claude-prompts/bin/query.sh "")' \
  --with-nth '2,3' \
  --delimiter '\t'
```

**Row format from `query.sh`:** Tab-separated columns:
```
<id>\t<display_oneline>\t<project_short>\t<display_full_escaped>
```
- `{1}` = id (hidden, used for pin toggle)
- `{2}` = display (one-line, shown in list)
- `{3}` = project basename (shown in list, dimmed)
- `{4}` = full display for preview / copy

**Pinned indicator:** `query.sh` prepends `\e[33m★\e[0m ` to `{2}` when `pinned=1`.

**Newline collapsing:** `query.sh` replaces `\n` with ` ↵ ` in the list column, shows full text in `{4}` for preview.

---

## 5. Pin Flow

```bash
# bin/pin.sh <id>
DB="$HOME/.local/share/claude-prompts/db.sqlite"
sqlite3 "$DB" "
  UPDATE prompts
  SET pinned = CASE WHEN pinned = 1 THEN 0 ELSE 1 END,
      pinned_at = CASE WHEN pinned = 0 THEN $(date +%s%3N) ELSE NULL END
  WHERE id = $1;
"
```

Pinned rows always sort first (`ORDER BY p.pinned DESC, ...`). The ★ glyph is injected by `query.sh` at display time — no separate column needed in fzf output.

---

## 6. Scope Flow

```bash
# bin/toggle-scope.sh
SCOPE_FILE="${XDG_RUNTIME_DIR:-/tmp}/claude-prompts.scope"
CURRENT_PROJECT="$(tmux display-message -p '#{pane_current_path}')"

if [ "$(cat "$SCOPE_FILE" 2>/dev/null)" = "" ]; then
  echo "$CURRENT_PROJECT" > "$SCOPE_FILE"
else
  echo -n "" > "$SCOPE_FILE"
fi
```

`query.sh` reads `$SCOPE_FILE` at invocation time — no env var threading needed. fzf header updates to show current scope on each reload (injected as first line of output).

---

## 7. Dependencies

| Tool | Min version | Notes |
|---|---|---|
| tmux | 3.2 | For `display-popup`, `display-message -p #{pane_current_path}` |
| bash | 4.4 | Associative arrays, `mapfile`; standard on Linux |
| sqlite3 | 3.9 | FTS5 included; Ubuntu 24.04 ships 3.45.1 ✓ |
| fzf | 0.27 | `--disabled` + `change:reload` flags; apt ships 0.44.1 ✓ |
| jq | 1.6 | JSON parsing; jq 1.7 installed ✓ |
| sha1sum | any | Part of coreutils; universally available |
| xclip or xdotool | any | For ctrl-y copy; optional, graceful fallback |

**Not needed:** Python, Ruby, Node, any compiled binary.

---

## 8. Tests (bats-core)

Test file locations: `tests/`

| Test | What it verifies |
|---|---|
| `ingestion_idempotent.bats` | Run ingest twice on same fixture → row count unchanged |
| `ingestion_dedup.bats` | Same (display, project) different timestamps → only one row, max(ts) kept |
| `ingestion_offset.bats` | Add lines to fixture after first ingest → only new lines processed |
| `search_basic.bats` | Query returns expected row |
| `search_prefix.bats` | "cloud" matches "cloudflare" |
| `search_fallback.bats` | Single char "c" triggers LIKE fallback, returns results |
| `search_scope.bats` | project filter excludes other projects |
| `pin_toggle.bats` | Pin then unpin → pinned=0, pinned_at=NULL |
| `pin_sort.bats` | Pinned rows appear before unpinned in empty-query results |
| `newline_collapse.bats` | display with \n stored collapsed in DB |
| `paste_skip.bats` | Entries starting with "[Pasted text" not ingested |

Fixture: `tests/fixtures/sample.jsonl` — 50 hand-crafted lines covering all edge cases.

---

## 9. Risks & Open Questions

| Risk | Severity | Mitigation |
|---|---|---|
| sqlite3 not installed on user machine | Medium | Installer script checks and prompts `apt install sqlite3 fzf` |
| fzf `--disabled` + `change:reload` requires ≥ 0.27 | Low | apt ships 0.44.1; add version check in init script |
| `XDG_RUNTIME_DIR` not set in tmux popup env | Low | Fallback to `/tmp/claude-prompts-$USER.scope` |
| `pane_current_path` returns wrong dir in popup | Medium | Test: use `#{pane_current_path}` of the *calling* pane, passed as env var on popup open |
| history.jsonl format changes (new fields) | Low | jq selects only known fields; extras silently ignored |
| Entries with hash collision (sha1) | Negligible | 40-char sha1 of short strings; treat as zero risk |
| pastedContents with contentHash only (stripped content) | Design | Already handled: we use `display` field only; pasted content body is not indexed |
| Initial full ingest on first run (~4 MB, 12k lines) | Low | ~2–4s one-time cost; show "Indexing..." message; subsequent runs are incremental |
| bats-core not installed | Low | Tests are dev-only; document install (`apt install bats` or via git submodule) |

### Open question for planner
- **tmux popup invocation:** Does the user want this bound to a tmux key (requiring `prefix`), a standalone shell alias/function, or both? The popup command itself is `tmux display-popup -E -w 80% -h 80% 'bash /path/to/bin/browse.sh'` — it just needs a trigger. Recommend: shell alias `cpb` + optional tmux bind in plugin init script.
- **Insert vs copy on enter:** When user selects a prompt, should it be (a) copied to clipboard, (b) typed into the current pane via `tmux send-keys`, or (c) user-configurable? This affects the `enter` bind in fzf.
- **`pastedContents` body storage:** Stripped entries (contentHash only) are common in newer records. Should we ever attempt to resolve those hashes? Currently: no — out of scope.
