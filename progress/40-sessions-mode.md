# Batch E — Session search mode (rev 2, post Codex co-review)

Goal: a second popup mode that searches full session transcripts (user prompts,
Claude's text responses, `!`-bash inputs) across `~/.claude/projects/*/*.jsonl`,
pinpoints the owning session, previews the rendered conversation anchored at the
end, and types `/resume <session-id>` into the originating pane on Enter.

Confirmed decisions (Joe, 2026-07-20):
- Entry: mode toggle inside the existing popup (Ctrl-E), not a second binding.
- Enter: type `/resume <session-id>` into the originating pane, no execution,
  no cd-prefix. Ctrl-O copies the same string.
- Index scope: dialogue + bash inputs. Tool calls stored as compact one-liners
  for preview rendering only (role `tool`), excluded from all search paths.

Measured facts:
- ~2971 session files, 1.7 GB raw; dialogue text ~3% of bytes (~50 MB index).
- fzf 0.44.1: `change-preview-window(a|b)` cycling, `follow`, `{q}`,
  transform-header/prompt all verified available; no generic `transform`.
- Records carry `sessionId`, `cwd`, ISO-8601 `timestamp`, `isSidechain`,
  `isMeta`. User records embed `<command-*>`/`<bash-*>`/caveat noise.
  Assistant `message.content[]` mixes `text`/`thinking`/`tool_use` in order.

Revisions from Codex co-review (progress note): session-level contentful FTS
instead of per-message external-content FTS; crash-safe byte cursors;
recoverable --force; role filters on every search path; ordering-preserving
assistant extraction; version-assertion updates in existing tests; preview
caps and sanitization; separate background ingest orchestration; scope union.

## 1. Schema v7 (schema.sql + helpers.sh migration)

- `sessions(id INTEGER PK, sid TEXT UNIQUE, project TEXT, file TEXT,
  first_ts INT, last_ts INT, msg_count INT, title TEXT)` + indexes on
  `last_ts DESC`, `project`. `title` = first kept user prompt, ≤120 chars.
- `session_messages(id INTEGER PK, session_id INT REFERENCES sessions(id),
  seq INT, role TEXT CHECK(role IN ('user','assistant','bash','tool')),
  ts INT, text TEXT)` + `UNIQUE(session_id, seq)` (crash-replay guard)
  + index `(session_id, seq)`.
- `session_fts` = **contentful** FTS5, ONE ROW PER SESSION (rowid =
  sessions.id), body = newline-joined text of that session's non-tool
  messages, same unicode61 tokenizer as prompts_fts. No triggers — the
  Python ingester is the only writer and refreshes a session's FTS row
  (delete + reinsert recomputed body) whenever it appends to that session.
  Rationale: multi-token AND queries match across turns; avoids
  external-content trigger fragility ('rebuild' would leak tool rows;
  'delete-all' + AD-trigger sequence corrupts the index — reproduced).
  Body clamped to 2 MB per session.
- `session_files(path TEXT PK, offset INT, mtime INT, dev INT, ino INT,
  fp TEXT)` — incremental cursor. `offset` = bytes consumed up to the last
  complete newline-terminated record; `fp` = sha1 of first min(4096, offset)
  bytes (rewrite detection).
- Fresh-DB path: schema.sql declares the tables, `PRAGMA user_version = 7`;
  helpers.sh ensure_db fresh path sets 7 (currently hard-codes 6 — must be
  updated) and gains a v6→v7 migration with identical DDL.
- Existing bats assertions pinning user_version 6 (groups.bats, ingest.bats
  migration ladder) updated to expect 7.

## 2. scripts/ingest_sessions.py (stdlib only)

- Env: `CP_DB`, `CP_PROJECTS_DIR` (default `$HOME/.claude/projects`),
  `CP_RUN_DIR`. Single-instance `fcntl.flock` on
  `$CP_RUN_DIR/session_ingest.lock`; exit 0 if held. Status file
  `$CP_RUN_DIR/session_ingest_status` (`running`/`done`) for the header.
- Enumerate `projects/*/*.jsonl` one level deep only (no recursion — nested
  subagent/workflow transcripts are out of scope).
- Per file, snapshot `st = stat()` first; never read past `st.st_size`.
  Skip when `(size == offset, mtime, dev, ino)` match and fp matches.
  Re-ingest from 0 (deleting the session's rows first) when size < offset,
  dev/ino changed, or prefix fingerprint mismatch. Else binary-read from
  `offset`, process only through the last `\n`-terminated record; the new
  offset points there (a partially written final record is re-read next run).
- One transaction per file: messages + sessions upsert + FTS refresh +
  cursor row commit atomically.
- Cheap pre-filter: only `json.loads` lines containing `"type":"user"` or
  `"type":"assistant"` (skips file-history snapshots, the bulk of bytes).
- Keep/skip rules:
  - skip `isSidechain`, `isMeta`
  - user string content: skip `<local-command-*`, `<command-*`,
    `<bash-stdout`, `<bash-stderr`; `<bash-input>` → strip tags, role `bash`
  - user array content: join `text` items only (tool_results dropped), then
    same filters
  - assistant: walk `message.content[]` IN ORDER, coalescing adjacent `text`
    blocks → role `assistant`; each `tool_use` → role `tool` one-liner
    `Name: <command|file_path|description|…>` ≤100 chars; `thinking` dropped
  - sanitize all stored text: strip control chars (incl. ESC and \x1e/\x1f)
    except \n\t; clamp message to 16 KB
- Timestamps: ISO-8601 `...Z` → ms epoch UTC; unparseable → carry last seen
  (0 if none). `sid` = file stem; `project` = first record `cwd`.
- After a COMPLETE enumeration (normal or --force), delete DB sessions whose
  files vanished. `--force` = treat every file as changed (per-file
  delete + re-ingest); never wipe-all-first, so interruption leaves a
  consistent partial index.
- Indexes the physical log incl. abandoned branches (parentUuid-chain
  filtering deferred).

## 3. Mode plumbing

- `scripts/session_mode.sh` — toggles `$CP_RUN_DIR/sessions`; on enable also
  clears `similar`/`group` state. (Global like all other mode state; the
  multi-popup limitation is pre-existing and accepted.)
- `dispatch.sh` — sessions branch first → `exec session_query.sh "$Q"`.
- `popup.sh`:
  - `rm -f "${CP_RUN_DIR}/sessions"` with the other stale-mode cleanup
  - session ingest is its OWN always-background job (both branches of the
    prompt-count check), with its own fzf nudge: reload + transform-header.
    Prompt ingest keeps its existing nudge; neither waits on the other.
  - preview command becomes `cheatsheet_preview.sh {1} {q}`
  - new bind `ctrl-e:execute-silent(session_mode.sh)
    +change-preview-window(down:70%:wrap:follow|down:30%:wrap)
    +reload(dispatch)+transform-header(header.sh)+transform-prompt(prompt.sh)`
  - `ctrl-r` additionally kicks a background incremental session ingest.
  - Documented quirks (fzf 0.44 cannot conditionally bind): Ctrl-] between
    two Ctrl-E presses drops `follow` until the next Ctrl-E; opening `?`
    while follow is active may show the cheatsheet bottom-anchored.
- Mode guards: `pin.sh`, `similar_toggle.sh`, `group_pick.sh`,
  `action_palette.sh` exit 0 when sessions mode is active — guard placed
  BEFORE any numeric-id validation.

## 4. scripts/session_query.sh

Mirrors query.sh structure (scope file, case file, FTS-sanitize, LIKE
fallback):
- Browse (empty query): sessions in scope, `ORDER BY last_ts DESC LIMIT 200`.
- FTS: `session_fts MATCH` (session-level doc → tokens may match across
  different turns), join sessions, recency-ordered. No hit counts (a
  session-level doc can't count message hits honestly; preview highlighting
  does the pinpointing).
- Case-sensitive: token-AND `instr()` over `session_messages.text` with
  `role IN ('user','assistant','bash')`. LIKE fallback likewise role-filtered
  (+ title).
- Scope: `sessions.project = <scope>`. `scope.sh list` becomes a
  prompts∪sessions union ordered by max recency; a scope empty in the
  current mode just shows an empty list.
- Row: `<sid>\x1f<ANSI line>` — project chip · title · msg count ·
  relative time. Renderer inline in the script (glyphs.sh colors).

## 5. scripts/session_preview.sh <sid> [query]

- `cheatsheet_preview.sh` routes: cheatsheet file → cheatsheet; sessions
  file → session_preview; else prompt preview ({q} arg ignored by
  preview.sh). Empty/invalid sid → friendly "(no session)" exit 0 (fzf runs
  the preview with no selection when {q} changes).
- Header block: title, project path, date range, message count, dim
  `/resume <sid>` line.
- Body: last N messages capped by BOTH message count (400) and total output
  budget (~200 KB / 4000 lines), older elided with a count marker:
  - `❯ ` cyan bold user turns
  - `! ` yellow bash inputs
  - plain assistant text
  - dim `⏺ Tool(arg)` one-liners
  - blank line between turns
- Query tokens highlighted reverse-video, LITERAL match (no regex
  metacharacters interpreted), case-insensitive.

## 6. Insert / copy

`insert.sh`: sessions-mode branch BEFORE the numeric-id validation. Payload
for `paste` / `paste-literal` / `copy` = literal `/resume <sid>` (sid
validated `^[0-9a-fA-F-]{8,}$`). Existing `send-keys -l` path types it with
NO trailing newline (test asserts no Enter reaches the pane).

## 7. bin/claude-prompts

New debug subcommands: `sessions-ingest [--force]`, `sessions-query <term>`.

## 8. header.sh / prompt.sh / cheatsheet.sh

- header: sessions-mode banner (count of sessions in scope, plus dim
  `indexing…` while the ingest status file says running) + footer hint swap
  (`enter /resume · ^o copy · ^e prompts`).
- prompt.sh: distinct session-mode indicator glyph before the query.
- cheatsheet: add Ctrl-E row; relabel Enter/Ctrl-O rows in session mode.

## 9. Tests (tests/sessions.bats + fixtures)

New fixture transcripts covering noise records (sidechain, meta, caveats,
bash-in/out, tool_use, thinking, ISO timestamps). Cases: ingest counts +
noise filtering; bash-input searchable; tool rows in preview data but
excluded from FTS AND from sensitive/LIKE paths; cross-turn multi-token
match; title extraction + sanitization; incremental append (cursor advances
only past complete records); partial-final-line handling; shrunken/rewritten
file re-ingest; unchanged-file skip; deleted-file reconciliation; browse
ordering; scope filter incl. union scope list; case-sensitive path; mode
toggle; dispatch routing; insert emits `/resume` with no trailing newline
via tmux mock; v6→v7 migration; fresh DB lands at v7; --force. Existing 55
cases stay green (version assertions updated to 7).

## 10. README

New "Session search" section + key table rows (Ctrl-E, session-mode
Enter/^O), first-sweep note, quirks.
