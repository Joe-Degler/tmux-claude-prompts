PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS prompts (
  id        INTEGER PRIMARY KEY,
  display   TEXT    NOT NULL,                      -- newlines collapsed (' ↵ ' marker)
  display_full TEXT NOT NULL,                      -- original, with newlines preserved
  display_preview TEXT NOT NULL DEFAULT '',        -- list-view rendering: snippet for marker-only rows, else == display
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
-- Normal (non-contentless) FTS5 mode: FTS5 stores its own copy of body.
-- Blueprint specified content='' (contentless) but contentless tables do not
-- support DELETE via rowid — they require the special
--   INSERT INTO fts(fts, rowid, body) VALUES('delete', rowid, old_body)
-- form, which needs the old body value available in the trigger context.
-- Since our triggers re-index (delete + re-insert) without storing old body,
-- normal FTS5 is the correct choice. Storage overhead is ~size of paste
-- content (≤3 MB in the sample dataset) — acceptable per §12 note.
CREATE VIRTUAL TABLE IF NOT EXISTS prompts_fts USING fts5(
  body,
  tokenize='unicode61 remove_diacritics 2'
);

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
