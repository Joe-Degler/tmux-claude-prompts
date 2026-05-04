# Orchestration Log — Claude Prompt Browser (tmux popup tool)

**Working dir:** `/opt/development/tmux-claude-prompts`
**Started:** 2026-05-04
**Role:** Claude (Opus 4.7) as orchestrator. All implementation work delegated to subagents.

## Goal
Build a tmux-integrated tool that lets the user browse, search, pin, and reuse prompts from `~/.claude/history.jsonl`.

## Confirmed facts (verified by orchestrator)
- `~/.claude/history.jsonl` exists, 11,919 lines, ~4 MB.
- Format per line: `{"display": "<prompt text>", "pastedContents": {...}, "timestamp": <ms epoch>, "project": "<absolute path>"}`
- File grows append-only; we should treat it as upstream-of-truth and ingest into our own store.

## Requirements (from user)
1. Search prompts case-insensitive, "smart" (fuzzy / token / substring acceptable).
2. Pin prompts (persists across sessions).
3. Scope filter: Everywhere | current Project.
4. Recent-first ordering by default.
5. Tmux integration — popup ideal, not bound to a default `prefix`-only key.
6. Survive compaction — orchestrator persists progress to files.
7. Bash-first; some test coverage; SQLite likely.
8. Clear, intuitive UI with iconography. Reference `design-principles` skill.

## Open questions to resolve via research
- Best tmux integration mechanism (popup, run-shell, key-table). Does it have to be `prefix + key`?
- TPM-style distribution conventions (so the user can install like other plugins).
- Storage: jsonl-only vs SQLite (FTS5 for smart search).
- TUI engine: `fzf` (powerful but minimal control), `gum` (pretty, limited list state), custom Bash + ANSI, or hybrid `fzf` with custom preview.
- How to detect "current project" from inside a tmux popup (tmux pane PWD).
- Pinning storage location and merge semantics.
- Test framework: `bats` is the standard for bash.

## Phases
- **P1 — Research (parallel)** [in progress]
  - R1: Tmux plugin/popup architecture, distribution, keybinding flexibility.
  - R2: Tech stack — storage, search engine, TUI choice, ingestion strategy.
  - R3: UI/UX design w/ iconography (consults `design-principles`).
- **P2 — Plan** (Opus subagent synthesizes R1–R3 into an implementation blueprint).
- **P3 — Build** (Sonnet subagents implement modules per blueprint).
- **P4 — Test & polish** (bats tests; manual smoke; docs).

## Subagent dispatch log
*(filled in as we go)*

## Decisions log

### 2026-05-04 — Pasted content must be first-class
User clarified: pasted content (`pastedContents` field) is frequent and useful and must be captured/resolved.

Verified format by sampling history.jsonl:
- 589/11919 entries (~5%) have non-empty `pastedContents`.
- Shape: `{"<id>": {"id": <int>, "type": "text", "content": "<full pasted text>"}}`.
- Markers in `display` look like `[Pasted text #1 +30 lines]` and reference `pastedContents["1"]`.

Implications for the build:
1. **Storage:** add `paste_contents(prompt_id INTEGER, paste_id INTEGER, type TEXT, content TEXT, PRIMARY KEY(prompt_id, paste_id))` table; **do not** drop entries whose display is paste-only — instead, keep them and index their paste content in FTS.
2. **FTS:** index `display || ' ' || group_concat(paste content, ' ')` — pasted content is searchable.
3. **Render:**
   - List row keeps the `[Pasted text #N +M lines]` marker (it conveys size).
   - Preview pane expands each marker inline (or in a clearly-delimited block) so the user sees the full context before inserting.
4. **Insert:** when the user presses Enter, the inserted text is the **resolved** prompt — every `[Pasted text #N +M lines]` marker is replaced by the corresponding `pastedContents[N].content`. This is the most useful default. Add a separate keybind (e.g. `Ctrl-L` for "literal") that inserts the unresolved display so the user can choose.
5. **Ingestion:** parse `pastedContents` with `jq` and write rows per paste into `paste_contents` plus an FTS body composed by a trigger on insert/update.
