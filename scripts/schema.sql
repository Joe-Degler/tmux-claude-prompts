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
  hash      TEXT    NOT NULL UNIQUE,               -- sha1(display_full || '\x1f' || project)
  label     TEXT    NULL                           -- optional short user-supplied label (≤60 chars)
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

-- Groups: user-defined named bundles of prompts.
CREATE TABLE IF NOT EXISTS groups (
  id   INTEGER PRIMARY KEY,
  name TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  ts   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS group_members (
  group_id  INTEGER NOT NULL REFERENCES groups(id)  ON DELETE CASCADE,
  prompt_id INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
  ts        INTEGER NOT NULL,
  PRIMARY KEY (group_id, prompt_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_prompt ON group_members(prompt_id);

-- FTS5 indexes display + concatenated paste contents (body) plus optional label.
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
  label,
  tokenize='unicode61 remove_diacritics 2'
);

-- INSERT on prompts → insert composed body+label into FTS
CREATE TRIGGER IF NOT EXISTS prompts_ai AFTER INSERT ON prompts BEGIN
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;

-- DELETE on prompts → delete from FTS (paste_contents cascade fires next)
CREATE TRIGGER IF NOT EXISTS prompts_ad AFTER DELETE ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
END;

-- UPDATE on prompts.display → re-index
CREATE TRIGGER IF NOT EXISTS prompts_au AFTER UPDATE OF display ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;

-- UPDATE on prompts.label → re-index
CREATE TRIGGER IF NOT EXISTS prompts_au_label AFTER UPDATE OF label ON prompts BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.id;
  INSERT INTO prompts_fts(rowid, body, label) VALUES (
    new.id,
    new.display || char(10) || COALESCE(
      (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = new.id),
      ''
    ),
    COALESCE(new.label, '')
  );
END;

-- INSERT on paste_contents → re-index parent prompt
CREATE TRIGGER IF NOT EXISTS paste_ai AFTER INSERT ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = new.prompt_id;
END;

-- UPDATE on paste_contents → re-index
CREATE TRIGGER IF NOT EXISTS paste_au AFTER UPDATE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = new.prompt_id;
END;

-- DELETE on paste_contents → re-index parent (if it still exists)
CREATE TRIGGER IF NOT EXISTS paste_ad AFTER DELETE ON paste_contents BEGIN
  DELETE FROM prompts_fts WHERE rowid = old.prompt_id;
  INSERT INTO prompts_fts(rowid, body, label)
  SELECT p.id,
         p.display || char(10) || COALESCE(
           (SELECT group_concat(content, char(10)) FROM paste_contents WHERE prompt_id = p.id),
           ''
         ),
         COALESCE(p.label, '')
  FROM prompts p WHERE p.id = old.prompt_id;
END;

-- Session transcripts: one row per Claude Code session file. sid is the
-- transcript filename stem (what `/resume <sid>` takes).
CREATE TABLE IF NOT EXISTS sessions (
  id        INTEGER PRIMARY KEY,
  sid       TEXT    NOT NULL UNIQUE,
  project   TEXT    NOT NULL DEFAULT '',
  file      TEXT    NOT NULL,
  first_ts  INTEGER NOT NULL DEFAULT 0,
  last_ts   INTEGER NOT NULL DEFAULT 0,
  msg_count INTEGER NOT NULL DEFAULT 0,
  title     TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_sessions_last_ts ON sessions(last_ts DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);

-- role 'tool' rows are preview-only: excluded from session_fts and from the
-- case-sensitive/LIKE search paths.
CREATE TABLE IF NOT EXISTS session_messages (
  id         INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,
  role       TEXT    NOT NULL CHECK (role IN ('user','assistant','bash','tool')),
  ts         INTEGER NOT NULL DEFAULT 0,
  text       TEXT    NOT NULL,
  UNIQUE (session_id, seq)
);

CREATE INDEX IF NOT EXISTS idx_session_messages_sess ON session_messages(session_id, seq);

-- Contentful FTS5, ONE ROW PER SESSION (rowid = sessions.id). Body is the
-- newline-joined non-tool message text, so multi-token AND queries match
-- across turns. No triggers: ingest_sessions.py is the sole writer and
-- refreshes a session's row (delete + reinsert) whenever it appends.
-- External-content FTS was rejected: 'rebuild' would index tool rows and
-- the 'delete-all' + delete-trigger sequence corrupts the index.
CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
  body,
  tokenize='unicode61 remove_diacritics 2'
);

-- Incremental ingest cursor. offset = bytes consumed up to the last complete
-- newline-terminated record; fp = sha1 of first min(4096, offset) bytes for
-- in-place-rewrite detection.
CREATE TABLE IF NOT EXISTS session_files (
  path   TEXT PRIMARY KEY,
  offset INTEGER NOT NULL DEFAULT 0,
  mtime  INTEGER NOT NULL DEFAULT 0,
  dev    INTEGER NOT NULL DEFAULT 0,
  ino    INTEGER NOT NULL DEFAULT 0,
  fp     TEXT    NOT NULL DEFAULT ''
);

PRAGMA user_version = 7;
