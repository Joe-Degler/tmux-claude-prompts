# Claude Prompt Browser — UI Design Spec

**Direction: Precision & Density.**
Developer tool opened mid-session, not a home screen. The user is already in Claude Code — no ceremony. Monochrome foundation, monospace throughout (prompt text is data), two accent colors: amber for pinned state, cyan for scope/action. Zero decorative elements.

---

## 1. Layout

Popup: 95% of terminal (configurable). Reference at 220×50 terminal → ~209×47 popup.
fzf handles the outer chrome; we control header, row format, footer, and preview.

```
┌─ Claude Prompts ──────────── 󰗺 Everywhere · 11,919 ──────────────┐  ← header (1 row)
│  > init_                                                          │  ← search (1 row)
│                                                                   │  ← separator
│ ★ •  tmux-claude-pr  /init what should the sqlite schema look…   │  ← selected row
│   ·  tmux-claude-pr  Please add a meta instruction section to …  │
│      api-service     Fix the auth middleware so tokens refresh…   │
│   •  dotfiles        Update zsh aliases for new brew paths        │
│      api-service     The integration tests are failing on CI …    │
│   ·  tmux-claude-pr  Investigate the rate limiting logic in th…   │
│                                                                   │
│  (empty rows — list fills available height)                       │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤  ← preview divider
│  /init what should the sqlite schema look like for storing      │  ← preview pane
│  prompt history? Consider: full text search via fts5, pinned    │  (6 rows)
│  entries, per-project scoping, deduplication on content hash.   │
│                                                                   │
│   tmux-claude-prompts · 3 minutes ago · 4 lines                  │
└───────────────────────────────────────────────────────────────────┘
│  enter insert  ^p pin  ^s scope  ^o copy  esc close              │  ← footer (1 row)
```

**Row budget (50-row popup):**
- Header: 1
- Search: 1
- Separator: 1
- List: ~34
- Preview divider: 1
- Preview: 6
- Footer: 1
- fzf border chrome: 5 (top/bottom/padding)

---

## 2. Row Anatomy

Fixed column layout. Total usable width ≈ popup_width − 2 (border chars).

```
COL  WIDTH  CONTENT
1    1      pin glyph: ★ (amber) | space
2    1      space (separator)
3    1      recency glyph: • | · | space
4    1      space (separator)
5    16     project chip (truncated to 14 + trailing space), dimmed in Everywhere mode, hidden in scoped mode
6    rest   prompt text, newlines collapsed to ↵, truncated with … at end
```

**Decision — recency glyph over relative time string:**
A single glyph costs 1 col and scans instantly. A time string ("2d ago") costs 6 cols and forces reading. The glyph is a heat signal, not a timestamp — the preview pane shows exact age. Use the glyph.

**Row examples (popup at 120 cols → text zone ≈ 95 cols):**

```
★ •  tmux-claude-pr  /init what should the sqlite schema look like for storing prompt hi…
  ·  api-service     Please add a meta instruction section to the end of CLAUDE.md so fu…
  •  dotfiles        Update zsh aliases — also check if brew shellenv still needs to be …
     api-service     The nightly integration tests are failing on CI with a 503 from the…
```

Pinned + slash command (amber ★, cyan · for <1d recency):
```
★ •  tmux-claude-pr  /init what should the sqlite schema look like…
```

Plain prose:
```
     api-service     Fix the auth middleware so tokens refresh before expiry, not after.
```

Multi-line prompt (↵ shows collapse):
```
  ·  dotfiles        Update zsh aliases for brew paths ↵ Also check shellenv block ↵ Ru…
```

Very long prompt (… at truncation):
```
     api-service     The nightly integration tests are consistently failing on CI with a …
```

---

## 3. Iconography Table

| Meaning           | Nerd Font              | ASCII fallback | Notes                                  |
|-------------------|------------------------|----------------|----------------------------------------|
| Pinned            | ★ (U+2605)             | *              | Amber accent. Not a Nerd Font glyph — universally available, visually distinct |
| Recent < 1 day    | • (U+2022)             | .              | Solid bullet — hot                     |
| Recent < 7 days   | · (U+00B7)             | ,              | Middle dot — warm                      |
| Recent ≥ 7 days   | (space)                | (space)        | Absence = cold. No glyph needed        |
| Project chip pfx  |  (nf-fa-folder, ) | >              | Appears only in Everywhere mode before chip |
| Scope: everywhere |  (nf-fa-globe, )  | *              | In header scope element                |
| Scope: project    |  (nf-fa-folder, ) | >              | In header scope element                |
| Search prompt     | > (fzf default)        | >              | fzf owns this; we don't override       |
| Insert action     |  (nf-md-keyboard_return, 1) | RET | In footer keymap hint            |
| Multi-line        | ↵ (U+21B5)             | \n             | Inline within prompt text              |
| Truncation        | … (U+2026)             | ...            | End of row text                        |

---

## 4. Keymap

Eight bindings. fzf defaults respected (arrow keys, PgUp/Dn, ctrl-a/e in search line are untouched).

| Key        | Action                                              | Rationale                                                     |
|------------|-----------------------------------------------------|---------------------------------------------------------------|
| `Enter`    | Insert selected prompt into originating pane (paste, no submit) | Primary action. Never auto-submits — user stays in control |
| `Ctrl-O`   | Copy to clipboard (no paste)                        | "O" for "output elsewhere." Non-conflicting with fzf defaults |
| `Ctrl-P`   | Toggle pin on selected row                          | "P" for pin. Mnemonic. Row stays in place, glyph flips       |
| `Ctrl-S`   | Toggle scope: Everywhere ↔ current project          | "S" for scope. Header updates instantly                       |
| `Ctrl-D`   | Delete from local store (not source jsonl)          | Kept. Power users need pruning. Requires no confirm — low-stakes since source is safe |
| `Ctrl-R`   | Reload / re-ingest from source jsonl                | "R" for refresh. Useful after a long session adds new prompts |
| `?`        | Toggle keymap overlay (replaces preview temporarily)| Discoverable for new users, zero cost for power users         |
| `Esc`      | Close popup, return focus to originating pane       | Universal escape. Ctrl-C also works (fzf default)             |

**Omitted:** no `Tab` multi-select — this tool inserts one prompt at a time. Keeping selection model simple.

---

## 5. Color & Emphasis

Two accents. No background fills — fzf renders inside tmux popup chrome.

| Element              | 256-color code          | Role                                              |
|----------------------|-------------------------|---------------------------------------------------|
| Pinned glyph ★       | `color 214` (amber)     | Single warm accent. Draws eye to pinned rows      |
| Recency • ·          | `color 244` (mid-gray)  | Dim — metadata, not content                       |
| Project chip         | `color 243` (dim-gray)  | Dimmed in Everywhere mode; hidden in scoped mode  |
| Scope indicator      | `color 81` (cyan)       | Interactive element in header — feels actionable  |
| Selected row bg      | fzf default reverse     | Don't fight fzf's selection rendering             |
| Header text          | bold, no bg color       | Weight creates hierarchy without color            |
| Count in header      | `color 244` (dim-gray)  | Secondary — interesting but not primary           |
| Footer hints         | `color 238` (faint-gray)| Near-invisible. Present but not noisy             |
| Preview text         | `color 252` (light-gray)| Slightly dimmer than list content — it's context |
| Preview metadata line| `color 243` (dim-gray)  | Age, project, line count                          |

**Rule:** amber appears only on ★. Cyan appears only on scope indicator and `Enter` action hint in footer. Everything else is grayscale.

---

## 6. Empty & Edge States

**No matches:**
```
┌─ Claude Prompts ──────────── 󰗺 Everywhere · 0 ───────────────────┐
│  > frobnicator_                                                   │
│                                                                   │
│              no prompts match "frobnicator"                       │
│                          esc to close                             │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
│  enter insert  ^p pin  ^s scope  ^o copy  esc close              │
```
Centered, minimal. No icon needed — absence is clear.

**First run / empty store:**
```
│              󰗺  ingesting history…                               │
```
Spinner would require polling loop — skip it. Static message, then fzf reloads via `--bind 'start:reload(...)` once ingest completes. No fake animation.

**Preview pane for long prompts:**
Always visible (6 rows, bottom). Shows full unwrapped text. This is the canonical way to read a truncated row — no separate mode needed. Preview renders via `--preview` with a bash formatter that wraps at preview-pane width.

```
├───────────────────────────────────────────────────────────────────┤
│  The nightly integration tests are consistently failing on CI   │
│  with a 503 from the auth service. I think the token refresh    │
│  race condition we discussed is the culprit. Can you look at    │
│  middleware/auth.js around line 140 and suggest a fix?          │
│                                                                   │
│   api-service · 2 days ago · 4 lines                            │
└───────────────────────────────────────────────────────────────────┘
```

**Narrow popup (< 70 cols):**
Drop project chip column. Drop footer row. List fills the saved space.

---

## 7. Header Content

```
  Claude Prompts    󰗺 [Everywhere]   11,919 
```
or when scoped:
```
  Claude Prompts     [tmux-claude-prompts]   847 
```

- App name: bold, left-anchored after small left pad
- Scope element: `<icon> [<name>]` — brackets make it feel interactive/selectable without a cursor. User sees `[Everywhere]` and intuits it's toggleable. Ctrl-S is the binding.
- Count: right-anchored, dim. Updates with scope toggle.
- Scope icon in cyan, brackets in dim-gray, name in default.

fzf `--header` string assembled by a shell function at launch and on each Ctrl-S reload.

---

## 8. Footer / Hint Line

One line. Rendered as fzf `--prompt` area is above, so footer goes in `--header` of a second fzf pass — or simpler: appended below via tmux popup border title or a trailing header line. Use a trailing `--header` line (fzf supports multi-line header).

```
  enter insert  ^p pin  ^s scope  ^o copy  esc close
```

- 5 bindings shown (the 5 most-reached-for)
- Dim gray (`color 238`)
- Separator is two spaces, not `|` — quieter
- `?` binding intentionally omitted from footer — it's the discovery hatch, not the primary flow

---

## 9. Animation & Feedback

**Pin toggle (`Ctrl-P`):**
fzf reloads the list with `--bind 'ctrl-p:execute(...)+reload(...)'`. The reload preserves cursor position by tracking the selected entry's ID and passing it to `--bind 'load:pos(...)'`. Glyph flips from ` ` to `★` (amber) in-place. No visual jump.

**Scope toggle (`Ctrl-S`):**
`reload(...)` call re-queries SQLite with new scope. Header string rebuilt and passed via `--header`. Instant — no transition. Count updates. The abruptness is correct: this is a filter change, not a navigation.

**After `Enter` (insert):**
1. fzf exits with selected text
2. Shell script calls `tmux send-keys -t <pane-id> "<prompt text>" ""` (no Enter appended)
3. Popup closes via `tmux display-popup` natural exit
4. Focus returns to originating pane, cursor sits at end of inserted text
5. User reviews and hits Enter themselves — we never auto-submit

**After `Ctrl-D` (delete):**
Row disappears on reload. No confirmation dialog — source jsonl is untouched. If user deletes by accident, `Ctrl-R` re-ingests from source (restores deleted rows). This is the undo path; document it in `?` overlay.

---

## 10. Accessibility & Fallbacks

**`CLAUDE_PROMPTS_NO_NERD=1`** activates ASCII glyph table:

| Nerd Font | ASCII |
|-----------|-------|
| ★         | *     |
|  (folder) | >     |
|  (globe)  | @     |
| ↵         | \n    |
| …         | ...   |
| • / ·     | . / , |

Detected automatically if `$TERM` reports a known non-Nerd terminal, or forced via env var. A single `GLYPHS` associative array in the shell init switches tables; all rendering paths reference `${GLYPHS[pin]}` etc. — no scattered conditionals.

**Narrow popup (< 70 cols):**
- Drop project chip (saves 17 cols)
- Drop footer row (saves 1 row, improves list density)
- Preview pane collapses to 3 rows
- Header count drops (saves space in header line)

Detection: fzf `$FZF_COLS` available via `--bind 'start:...'` or pre-computed in launch script from `tmux display-message -p '#{popup_width}'`.
