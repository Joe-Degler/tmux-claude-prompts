# tmux-claude-prompts

Search, pin, and scope your Claude conversation history from a tmux popup. Prompts are indexed in a local SQLite/FTS5 database for instant full-text search. When you select a prompt and press Enter, pasted content embedded in the prompt is resolved inline and the result is inserted directly into the originating pane.

---

## Why

Claude's `~/.claude/history.jsonl` grows fast. Finding that one prompt you wrote two weeks ago — especially if it was mostly a pasted block — is tedious in a text editor. This plugin puts a searchable popup on `Alt+P`, remembers which prompts matter (pin), and scopes the list to the current project automatically.

---

## Install

### Manual (dev / symlink)

```bash
mkdir -p ~/.tmux/plugins
ln -sf /opt/development/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
chmod +x /opt/development/tmux-claude-prompts/claude-prompts.tmux
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-prompts/claude-prompts.tmux
```

Reload: `tmux source ~/.tmux.conf`

### TPM

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin '<your-github-user>/tmux-claude-prompts'
run '~/.tmux/plugins/tpm/tpm'
```

TPM installs on `prefix + I`.

---

## Keys

The default binding is `Alt+P` in the **root** table — no tmux prefix required.

| Key | Action |
|---|---|
| `Alt+P` | Open popup (default; no prefix needed) |
| `Enter` | Insert **resolved** prompt into originating pane |
| `Ctrl-L` | Insert **literal** display (paste markers unresolved) |
| `Ctrl-O` | Copy resolved prompt to clipboard |
| `Ctrl-P` | Toggle pin on selected row |
| `Ctrl-S` | Toggle scope (Everywhere / Project) |
| `Ctrl-T` | Toggle case sensitivity. The `Aa` chip in the header is dim when insensitive (default), bright cyan when sensitive |
| `Ctrl-D` | Delete row from local store (recoverable via Ctrl-R) |
| `Ctrl-R` | Force re-ingest from history.jsonl |
| `?` | Toggle preview pane |
| `Esc` | Close popup |

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

Claude stores pasted blocks as `pastedContents` objects in `history.jsonl`. This plugin:

- Captures those blocks into a normalized `paste_contents` table at ingest time.
- Indexes paste content in FTS5 alongside the prompt display text — so searching for a function name or error message finds prompts even when the match is only in the pasted block.
- In the list view, markers are shown as-is: `[Pasted text #1 +3 lines]`.
- **Enter** resolves markers: the inserted text has the full paste content substituted inline.
- **Ctrl-L** inserts the raw text with markers intact — useful if you want to edit the prompt before re-sending.

---

## Standalone usage

Outside a tmux session, use the dispatcher directly:

```bash
/opt/development/tmux-claude-prompts/bin/claude-prompts open
```

The fzf loop runs in your current terminal. Enter copies the resolved prompt to the clipboard (no pane to paste into). Other subcommands are also available:

```
claude-prompts ingest [--force]
claude-prompts query <search-term>
claude-prompts pin <id>
claude-prompts scope <toggle|get|set <path>>
claude-prompts insert <paste|paste-literal|copy> <id>
claude-prompts version
```

---

## Architecture

The tmux keybind fires `scripts/launch.sh`, which captures the originating pane id and current path, then opens a `tmux display-popup` running `scripts/popup.sh`. Inside the popup, `popup.sh` runs an incremental ingest sweep (fast no-op when no new bytes) and then launches fzf in `--disabled` mode. Every keystroke triggers `scripts/query.sh`, which queries the SQLite/FTS5 database and emits pre-formatted rows. On Enter, fzf calls `scripts/insert.sh paste <id>`, which fetches `display_full`, pipes it through `scripts/resolve.sh` to expand paste markers, then feeds the result to `tmux load-buffer -` (stdin) followed by `tmux paste-buffer -p -d -t <pane>` to insert into the originating pane without touching the clipboard. Ctrl-L skips resolution and sends the literal markers.

---

## Dependencies

| Dependency | Version | Notes |
|---|---|---|
| `tmux` | >= 3.2 | `display-popup`, `load-buffer -` |
| `bash` | >= 4.4 | Associative arrays, `nameref` |
| `sqlite3` | >= 3.9 | Must be compiled with FTS5 |
| `fzf` | >= 0.44 | `transform-header` action |
| `jq` | >= 1.6 | JSONL parsing in ingest |
| `gawk` | any | Required by `preview.sh` (3-argument `match()`) |
| `sha1sum` | any | Prompt deduplication hash |

Optional clipboard tools (used when outside tmux or on Ctrl-O): `clip.exe` (WSL), `wl-copy`, `xclip`, `xsel`, `pbcopy`.

A Nerd Font is recommended for pin/recency glyphs. Set `@claude_prompts_no_nerd 1` or `CLAUDE_PROMPTS_NO_NERD=1` to use ASCII fallbacks.

---

## Troubleshooting

**Popup opens but list is empty.**
Run `bin/claude-prompts ingest --force`. The first full ingest reads `~/.claude/history.jsonl` from scratch. If that file does not exist, Claude has not written any history yet.

**Glyphs look wrong (boxes, question marks).**
Install a Nerd Font (e.g. JetBrainsMono Nerd Font) and configure your terminal to use it, or disable Nerd glyphs: add `set -g @claude_prompts_no_nerd 1` to `~/.tmux.conf`.

**Pasted content is not being resolved on Enter.**
Make sure you are pressing `Enter` (not `Ctrl-L`). `Ctrl-L` intentionally inserts the literal markers. If resolved content is blank, run `bin/claude-prompts query <term>` to confirm the prompt has paste rows.

**Plugin key not bound after install.**
Run `tmux source ~/.tmux.conf`, then verify with `tmux list-keys -T root M-p`. If still missing, confirm `claude-prompts.tmux` is executable (`chmod +x`).

**"your sqlite was built without FTS5" error.**
Install the system `sqlite3` package (not just `libsqlite3-dev`). On Ubuntu/Debian: `sudo apt-get install sqlite3`. The system package is built with FTS5; the development headers package is not always sufficient.

---

## Tests

Requires `bats-core` (version 1.x):

```bash
npm install -g bats      # or: brew install bats-core
bats tests/
```

All 27 cases should pass: 8 ingest, 8 query, 5 pin, 6 insert.

---

## License

MIT
