# tmux-claude-prompts

Search, pin, label, and group your Claude Code prompt history from a tmux popup. Prompts and their pasted content are indexed in a local SQLite/FTS5 database for instant full-text and semantic search. Press Enter and the selected prompt — with paste markers fully resolved — is typed directly into the originating pane.

---

## Why

Claude Code's `~/.claude/history.jsonl` grows fast and the prompts you actually want to re-use are buried under throwaways. This plugin keeps the database local and adds:

- **Instant search** across prompt text and pasted blocks (FTS5)
- **Session search** — a second mode (`Ctrl-E`) that searches full session transcripts, including Claude's responses, and types `/resume <session-id>` into your pane
- **Semantic similar-mode** to find related prompts even when phrasing differs
- **Curation** — pin starred prompts, give them labels, organize into groups
- **Project scoping** — see only the prompts from the cwd you launched from
- **Paste recovery** — pasted blobs are pulled from `~/.claude/paste-cache/` at ingest time and persisted, so they survive Claude Code's cache eviction

---

## Install

Check the [dependencies section](#dependencies) first — `tmux ≥ 3.2`, `bash ≥ 4.4`, `sqlite3` with FTS5, `fzf ≥ 0.44`, `jq`, `gawk`, `sha1sum`, and `python3` (stdlib only) must all be on `PATH`.

### TPM (recommended)

```tmux
set -g @plugin 'Joe-Degler/tmux-claude-prompts'
run '~/.tmux/plugins/tpm/tpm'
```

Reload `~/.tmux.conf`, then `prefix + I` to install. Press `Alt+P` to open the popup. The first launch runs an ingest sweep over `~/.claude/history.jsonl`; subsequent launches are incremental.

### Manual clone

```bash
git clone https://github.com/Joe-Degler/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
chmod +x ~/.tmux/plugins/tmux-claude-prompts/claude-prompts.tmux
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-prompts/claude-prompts.tmux
```

Reload: `tmux source ~/.tmux.conf`.

### Symlink (development)

If you have a working tree elsewhere and want tmux to pick it up directly:

```bash
ln -sf /path/to/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
chmod +x /path/to/tmux-claude-prompts/claude-prompts.tmux
```

Same `run-shell` line in `~/.tmux.conf`, then reload.

### First-run notes

- The SQLite database lives under `$XDG_DATA_HOME/claude-prompts/db.sqlite` (typically `~/.local/share/claude-prompts/db.sqlite`). It is created on first popup launch.
- Schema migrations run automatically on every launch and are idempotent — safe to upgrade in place.
- Pasted content is captured from `~/.claude/history.jsonl` and `~/.claude/paste-cache/` at ingest time and persisted in the local DB. Pastes are recovered even if Claude Code later evicts its cache, but only for prompts ingested while the cache was still warm.

---

## Keys

The default binding is `Alt+P` in the **root** table — no tmux prefix required. Press `?` inside the popup at any time to see the full keymap as a cheatsheet.

### Insert / copy

| Key | Action |
|---|---|
| `Enter` | Insert **resolved** prompt (paste markers expanded) into originating pane |
| `Ctrl-L` | Insert **literal** display (paste markers unresolved) |
| `Ctrl-O` | Copy resolved prompt to clipboard |

### Search controls

| Key | Action |
|---|---|
| `Ctrl-S` | Toggle scope (Everywhere / Project) |
| `Shift-←/→` | Cycle through every project scope by recency |
| `Ctrl-T` | Toggle case sensitivity (`Aa` chip dim = insensitive, cyan = sensitive) |
| `Ctrl-/` | Toggle similar mode — semantic neighbours of the focused row; query string further refines via lexical AND-filter |
| `Ctrl-E` | Toggle session-search mode — search full transcripts (including Claude's responses); Enter types `/resume <session-id>` |

### Curation

| Key | Action |
|---|---|
| `Ctrl-P` | Toggle pin on focused row |
| `Ctrl-G` | Open group picker (select existing or create new; auto-pins on add) |
| `Ctrl-A` | Row-actions palette (group-add · label · delete) |

### Preview

| Key | Action |
|---|---|
| `Shift-↑/↓` | Scroll preview by one line |
| `Alt-↑/↓` | Scroll preview by half a page |
| `` Ctrl-] `` | Cycle preview size (30% → 80% → hidden → 30%) |
| `?` | Toggle cheatsheet overlay (replaces preview while held) |

### Lifecycle

| Key | Action |
|---|---|
| `Alt+P` | Open popup (default; no prefix needed) |
| `Ctrl-R` | Force re-ingest from `history.jsonl` |
| `Ctrl-Q` | Close popup (preferred — no terminal disambiguation lag) |
| `Alt-Q` | Close popup (alias for `Ctrl-Q`) |
| `Esc` | Close popup (kept for power users; brief lag while terminal disambiguates) |

### Overriding the default key

```tmux
set -g @claude_prompts_key M-h            # change to Alt+H
set -g @claude_prompts_key_table prefix   # require tmux prefix first
set -g @claude_prompts_prefix_key p       # also bind prefix + p (optional)
```

---

## Configuration

All options are tmux user options set in `~/.tmux.conf`.

| Option | Default | Description |
|---|---|---|
| `@claude_prompts_key` | `M-p` | Primary keybinding |
| `@claude_prompts_key_table` | `root` | `root` (no prefix) or `prefix` |
| `@claude_prompts_prefix_key` | (empty) | Optional secondary prefix-table binding; empty = disabled |
| `@claude_prompts_popup_size` | `90%` | Popup width and height |
| `@claude_prompts_no_nerd` | (empty) | Set to `1` to force ASCII glyphs (no Nerd Font required) |

You can also set `CLAUDE_PROMPTS_NO_NERD=1` in your shell environment for the same effect.

---

## Pasted content handling

Claude Code stores paste markers (`[Pasted text #N +M lines]`) in `~/.claude/history.jsonl` and the actual bodies under `~/.claude/paste-cache/<contentHash>.txt`. This plugin:

- Reads paste bodies from `paste-cache` at ingest time and persists them to a local `paste_contents` table — so you keep them even after Claude Code evicts the cache.
- Indexes paste content in FTS5 alongside the prompt display text. Searching for a function name or error message finds prompts where the match is only in the pasted block.
- In the preview pane, markers are inlined automatically.
- Three resolution sources are tried in order: inline `pastedContents.content` (legacy), `paste-cache/<hash>.txt` (current Claude Code), session JSONL extraction (fallback for genuinely empty entries).
- **Enter** inserts with markers fully resolved.
- **Ctrl-L** inserts the raw text with markers intact — useful for editing before re-sending.

If a row shows `[Pasted Text Lost]`, the cache file was already evicted before this plugin first ingested that prompt. Future prompts ingest as-they-arrive and won't have this issue.

---

## Groups & labels

Curate prompts you want to keep around without scrolling forever.

- **Pin** (`Ctrl-P`) marks a prompt as starred. Pinned prompts float to the top of every result set and are sticky across deletes.
- **Label** (`Ctrl-A → label`) attaches a short name (≤ 60 chars) to a prompt for easy recognition. Labels are FTS-indexed so you can search them. Setting a label auto-pins the prompt.
- **Groups** (`Ctrl-G` to add, `Ctrl-A → group-add` from the palette) are user-defined collections — your "snippets folder." Adding a prompt to a group auto-pins it. Selecting a group from the picker scopes the popup to that group's members; pick the synthetic "exit group mode" row to leave.

Groups and labels both persist across re-ingests; deleting a prompt also detaches it from any groups (cascade).

---

## Session search

Press `Ctrl-E` to flip the popup into **session mode**: instead of individual prompts, each row is one Claude Code session, searchable by anything either of you said. This is the "which session was that in, and how do I get back" mode.

- **What's indexed:** your prompts, Claude's text responses, and your `!`-prefix bash inputs, from every top-level transcript under `~/.claude/projects/`. Tool calls appear in the preview as compact dim one-liners but are not searchable; tool output, thinking blocks, and subagent transcripts are excluded entirely.
- **Search semantics:** multi-token queries match across turns — `widget sprocket` finds a session where you said "widget" and Claude answered about "sprockets". Scope (`Ctrl-S`, `Shift-←/→`) and case toggle (`Ctrl-T`) work as in prompt mode; scope cycling only visits projects that actually have sessions (and only prompt-projects in prompt mode). Switching modes while scoped to a project with no rows on the other side falls back to Everywhere.
- **Preview:** a rendered transcript, opened at the **end** of the conversation (where you stopped), with `>` user turns, `!` bash inputs, and query matches highlighted. Scroll up with the usual preview keys. Long sessions show the last ~400 messages.
- **Enter** types `/resume <session-id>` into the originating pane — it does not press Enter for you, so you can cd or switch panes first. `Ctrl-O` copies the same string. `Ctrl-L` behaves like Enter here.
- **Indexing:** runs in the background on popup open (incremental, ~30 ms when nothing changed; the first sweep takes a few seconds). `Ctrl-R` also kicks a re-scan. The header shows `indexing…` while a sweep is running.
- Pin/group/label keys are inert in session mode — those are prompt-mode concepts.

Two known cosmetic quirks (fzf cannot re-bind keys conditionally): cycling preview size with `Ctrl-]` while in session mode drops the bottom-anchoring until you toggle `Ctrl-E` again, and opening the `?` cheatsheet in session mode may show it bottom-anchored.

Sessions whose transcript files Claude Code has already cleaned up (see its `cleanupPeriodDays` setting) cannot be indexed — only transcripts still on disk are searchable.

---

## Standalone usage

Outside a tmux session, use the dispatcher directly:

```bash
~/.tmux/plugins/tmux-claude-prompts/bin/claude-prompts open
```

The fzf loop runs in your current terminal. Enter copies the resolved prompt to the clipboard (no pane to paste into). Subcommands:

```
claude-prompts open                                Launch popup or standalone fzf
claude-prompts ingest [--force]                    Incremental (or full) re-ingest
claude-prompts query <search-term>                 Emit raw fzf rows (debug)
claude-prompts pin <id>                            Toggle pin on a row
claude-prompts scope <toggle|get|set <path>>       Manage current scope
claude-prompts case  <toggle|get|set <mode>>       Manage case sensitivity
claude-prompts insert <paste|paste-literal|copy> <id>
claude-prompts group  <list|create <name>|delete <id>|rename <id> <name>>
claude-prompts label  <id> [<text>]                Set/clear a prompt label
claude-prompts sessions-ingest [--force]           Incremental (or full) session-transcript ingest
claude-prompts sessions-query <search-term>        Emit raw session-mode fzf rows (debug)
claude-prompts version
claude-prompts help
```

---

## Architecture

The tmux keybind fires `scripts/launch.sh`, which captures the originating pane id and current path, then opens a `tmux display-popup` running `scripts/popup.sh`. Inside the popup, `popup.sh` clears stale mode files, runs an incremental ingest sweep (fast no-op when no new bytes), and launches fzf in `--disabled` mode. Every keystroke triggers `scripts/query.sh`, which queries SQLite/FTS5 with the active scope, case, similar, and group filters, and emits pre-formatted rows.

On Enter, fzf calls `scripts/insert.sh paste <id>`, which fetches `display_full`, pipes it through `scripts/resolve.sh` to expand paste markers from `paste_contents`, then feeds the result to `tmux load-buffer -` followed by `tmux paste-buffer -p -d -t <pane>` so the text is typed into the originating pane without touching the clipboard. `Ctrl-L` skips resolution and sends the literal markers.

The action palette (`Ctrl-A`) is itself a small fzf instance that returns the chosen verb to the outer loop, which then dispatches to the matching script (`group_add.sh`, `label_set.sh`, `delete.sh`).

Session mode is driven by `ingest_sessions.py` (stdlib-only Python), which incrementally indexes `~/.claude/projects/*/*.jsonl` with crash-safe byte cursors (only complete, newline-terminated records are consumed; cursor and rows commit in one transaction per file). Search uses a session-level FTS5 document per session so multi-token queries match across turns; `session_query.sh` emits the rows and `session_preview.sh` renders the transcript tail.

Mode state files live under `$CP_RUN_DIR` (`/run/user/<uid>/claude-prompts/` by default) — `similar`, `group`, `case`, `scope`, `cheatsheet`, `sessions` — and are cleaned up on popup launch.

---

## Dependencies

| Dependency | Version | Notes |
|---|---|---|
| `tmux` | ≥ 3.2 | `display-popup`, `load-buffer -` |
| `bash` | ≥ 4.4 | Associative arrays, `nameref` |
| `sqlite3` | ≥ 3.9 | Must be compiled with FTS5 |
| `fzf` | ≥ 0.44 | `transform-header`, `transform-prompt` actions |
| `jq` | ≥ 1.6 | JSONL parsing in ingest |
| `python3` | ≥ 3.9 | Stdlib only — paste recovery, preview rebuild, backfill migration |
| `gawk` | any | Required by `preview.sh` (3-argument `match()`) |
| `sha1sum` | any | Prompt deduplication hash |

Optional clipboard tools (used outside tmux and on `Ctrl-O`): `clip.exe` (WSL), `wl-copy`, `xclip`, `xsel`, `pbcopy`.

A Nerd Font is recommended for pin/group/recency glyphs. Set `@claude_prompts_no_nerd 1` or `CLAUDE_PROMPTS_NO_NERD=1` for ASCII fallbacks.

---

## Troubleshooting

**Popup opens but list is empty.**
Run `bin/claude-prompts ingest --force`. The first full ingest reads `~/.claude/history.jsonl` from scratch. If that file does not exist, Claude Code has not written any history yet.

**Glyphs look wrong (boxes, question marks).**
Install a Nerd Font (e.g. JetBrainsMono Nerd Font) and configure your terminal to use it, or disable Nerd glyphs: `set -g @claude_prompts_no_nerd 1` in `~/.tmux.conf`.

**Pasted content shows `[Pasted Text Lost]`.**
The paste body was no longer in `~/.claude/paste-cache/` when ingest ran. Claude Code GCs that cache aggressively. Prompts ingested from now on will retain their pastes; old prompts are unrecoverable from this machine.

**Pasted content is not being resolved on Enter.**
Make sure you are pressing `Enter` (not `Ctrl-L`). `Ctrl-L` intentionally inserts literal markers. If resolved content is blank, run `bin/claude-prompts query <term>` to confirm the prompt has paste rows.

**Esc feels laggy when closing the popup.**
That's terminal Esc-disambiguation, not the plugin. Use `Ctrl-Q` (or `Alt-Q`) instead — both close instantly.

**Plugin key not bound after install.**
Run `tmux source ~/.tmux.conf`, then verify with `tmux list-keys -T root M-p`. If still missing, confirm `claude-prompts.tmux` is executable (`chmod +x`).

**"your sqlite was built without FTS5" error.**
Install the system `sqlite3` package (not just `libsqlite3-dev`). On Ubuntu/Debian: `sudo apt-get install sqlite3`. The system package is built with FTS5; the development headers package is not always sufficient.

**Session mode is empty or missing recent sessions.**
The background indexer may still be running (the header shows `indexing…`). If a session is genuinely absent, its transcript was likely cleaned up by Claude Code already — check `~/.claude/projects/<project-slug>/`. `bin/claude-prompts sessions-ingest --force` rebuilds the session index from what's on disk.

**Group mode won't go away.**
Press `Ctrl-G` and select the synthetic `(no group — exit group mode)` row at the top of the picker. Or close and reopen the popup — stale mode files are cleared on launch.

---

## Tests

Requires `bats-core` (version 1.x):

```bash
npm install -g bats      # or: brew install bats-core
bats tests/
```

78 cases across `ingest`, `query`, `pin`, `insert`, `groups`, and `sessions` suites should pass.

---

## License

MIT
