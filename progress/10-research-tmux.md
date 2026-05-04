# R1 — Tmux Plugin / Popup Architecture Research

**Date:** 2026-05-04  
**Tmux version in environment:** 3.4  
**Purpose:** Concrete reference for building `tmux-claude-prompts` as a TPM-installable plugin.

---

## 1. `display-popup` Flags and Behavior

`display-popup` (alias `popup`) was introduced in tmux 3.2. All flags below are available in tmux 3.4.

| Flag | Meaning | Notes |
|------|---------|-------|
| `-E` | Auto-close popup when shell-command exits | Use this. Without it the popup stays open. Double `-EE` closes only on exit code 0. |
| `-w <width>` | Width in columns or `%` (e.g. `80%`) | Default: half terminal width |
| `-h <height>` | Height in rows or `%` (e.g. `70%`) | Default: half terminal height |
| `-x <pos>` | Horizontal position (`C` = center, `R` = right, numeric) | Same semantics as `display-menu -x` |
| `-y <pos>` | Vertical position (`C` = center, `P` = near status line) | |
| `-d <dir>` | Start directory for the popup shell | Use `#{pane_current_path}` of the originating pane |
| `-e VAR=val` | Set an environment variable inside the popup | Can be given multiple times. **This is how we pass the originating pane ID.** |
| `-T <title>` | Title string (tmux format allowed) | e.g. `-T " Claude Prompts "` |
| `-b <border-lines>` | Border character style: `single` (default), `rounded`, `double`, `heavy`, `simple` | |
| `-s <style>` | Style for popup interior (fg/bg colors) | e.g. `-s fg=colour238,bg=colour235` |
| `-S <style>` | Style for popup border | |
| `-B` | Suppress border entirely | Overrides `-b` |
| `-c <target-client>` | Target client (defaults to current) | Usually omitted |
| `-t <target-pane>` | Target pane for context (affects `-d` default) | |

### Pitfalls

- **Border is drawn by default.** The popup content area shrinks by 1 cell on each side. Account for this when sizing.
- **Escape key closes the popup immediately** — if the inner TUI captures Escape for search clearing, consider binding `q` as the exit key and suppressing Escape handling in fzf/custom TUI.
- **Panes do not update while popup is visible.** Any pane that was running output is paused. This is expected and fine.
- **`TMUX_PANE` inside the popup refers to the popup's own pseudo-pane, NOT the originating pane.** Always pass the originating pane ID explicitly via `-e`.
- **Exit code 129** means the popup was interrupted (e.g. another popup opened). Extrakto works around this with a retry loop. We don't need that unless we support nested tmux sessions.
- **`-d` with format strings:** The value is evaluated at bind time, not at invocation time, unless you wrap in `run-shell`. Use `run-shell` to defer evaluation:
  ```
  bind-key -n M-p run-shell 'tmux popup -E -e ORIG_PANE=#{pane_id} -d "#{pane_current_path}" ...'
  ```
- **tmux 3.2 minimum** for `display-popup`. Guard with version check if you want broader compat.

---

## 2. TPM Distribution Conventions

### What TPM does

TPM (`~/.tmux/plugins/tpm`) is initialized by adding to `~/.tmux.conf`:
```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'your-user/tmux-claude-prompts'
run '~/.tmux/plugins/tpm/tpm'
```

On startup, TPM's `scripts/source_plugins.sh` discovers every `*.tmux` file in each plugin's directory and **executes it as a shell executable** (not `source`):
```bash
$tmux_file >/dev/null 2>&1
```

So the `.tmux` file runs as a standalone shell script with `/usr/bin/env bash` and must call `tmux bind-key` etc. itself.

### Required plugin structure

```
~/.tmux/plugins/tmux-claude-prompts/
├── claude-prompts.tmux          # TPM entrypoint — must be executable, must be *.tmux
├── scripts/
│   ├── helpers.sh               # shared functions (get_option, clipboard detection)
│   ├── popup.sh                 # launches the popup
│   └── send-to-pane.sh          # sends chosen prompt to originating pane
└── bin/
    └── claude-prompts           # main TUI binary (bash or any lang)
```

### Naming convention

- The file TPM executes must end in `.tmux`.  
- Convention (tmux-yank, extrakto): name it after the plugin, e.g. `claude-prompts.tmux`.  
- Multiple `*.tmux` files in the same dir are all executed — avoid accidental extras.

### Development workflow (DX)

During development, symlink the repo into the plugins dir:
```bash
ln -sf /opt/development/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
```
Then reload config (`prefix + r` or `tmux source ~/.tmux.conf`). TPM re-executes the `.tmux` file. No reinstall needed.

### Real-world examples studied

| Plugin | Entrypoint pattern |
|--------|-------------------|
| **tmux-yank** | Sources `helpers.sh`, calls `tmux bind-key` in prefix table, invokes `scripts/*.sh` via `run-shell -b` |
| **extrakto** | Sources `helpers.sh`, reads `@extrakto_key` option (default `tab`), binds `run-shell "open.sh #{pane_id}"` in **prefix table** |
| **tmux-fingers** | Resolves binary path, invokes `load-config` via `run-shell` |

---

## 3. Keybinding Flexibility

### Root table (no prefix required)

```tmux
bind-key -n M-p display-popup ...   # Alt+p with NO prefix
bind-key -T root M-p display-popup ...   # identical, -n is alias for -T root
```

**Trade-offs of root-table binding:**
- Pro: One keypress to open — much faster UX.
- Con: Can shadow applications that use the same key. `M-p` (Alt+P) is generally safe; avoid `C-p`, `C-l`, arrow keys.
- The man page notes: "binding 'c' to new-window in the root table (not recommended) means a plain 'c' will create a new window." — modifier-based combos like `M-p` are fine.

### Prefix table (traditional)

```tmux
bind-key p display-popup ...   # prefix + p
```

### Chord (multi-key sequence)

Tmux supports chord sequences via custom key tables and `switch-client -T`:
```tmux
# prefix + g then p → open prompt browser
bind-key -T prefix g switch-client -T claude_table
bind-key -T claude_table p run-shell "..."
```
This is clean but adds two keypresses. Probably overkill for this tool.

### User-override convention

The standard pattern (used by tmux-yank, extrakto) is to read from a tmux `@` user option with a fallback default:
```bash
# In helpers.sh
get_option() {
    local option="$1"
    local default="$2"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null)
    echo "${value:-$default}"
}
```
Then in the entrypoint:
```bash
key=$(get_option "@claude_prompts_key" "M-p")
table=$(get_option "@claude_prompts_key_table" "root")
tmux bind-key -T "$table" "$key" run-shell "'$SCRIPTS_DIR/popup.sh' '#{pane_id}'"
```

Users configure in `~/.tmux.conf` before the `run` line:
```tmux
set -g @claude_prompts_key "M-p"          # default: Alt+P, no prefix
set -g @claude_prompts_key_table "root"   # "root" or "prefix"
```

**Recommended default:** `M-p` in the root table (Alt+P). No prefix required. Override via `@claude_prompts_key` and `@claude_prompts_key_table`.

---

## 4. Sending Text Back to the Originating Pane

### The core pattern (extrakto / verified)

```python
# extrakto_plugin.py — the canonical approach:
subprocess.run(["tmux", "set-buffer", "--", text], check=True)
subprocess.run(["tmux", "paste-buffer", "-p", "-t", trigger_pane], check=True)
```

In shell:
```bash
# send-to-pane.sh <pane_id> <text>
pane_id="$1"
text="$2"
tmux set-buffer -- "$text"
tmux paste-buffer -p -t "$pane_id"
```

**`-p` on `paste-buffer`**: respects bracketed paste mode if the receiving application (Claude Code) has requested it. This is correct — Claude Code's readline interface will accept it cleanly.

### Alternative: `send-keys -l`

```bash
tmux send-keys -t "$pane_id" -l "$text"
```

`-l` treats the argument as literal UTF-8, not key names. Works but does NOT respect bracketed paste — some terminal apps may misinterpret special characters. Avoid for multi-line prompts.

### Alternative: `load-buffer` then `paste-buffer`

```bash
printf '%s' "$text" | tmux load-buffer -
tmux paste-buffer -p -t "$pane_id"
```

Equivalent to `set-buffer` for our purposes. `set-buffer --` is cleaner for single values.

### OSC 52 (clipboard escape sequence)

OSC 52 writes to the system clipboard. Useful as a fallback when not in tmux, but inside tmux it goes through tmux's clipboard handler. Not needed when you have direct `paste-buffer` access. Use for the standalone (non-tmux) fallback only.

### Getting the originating pane ID

**The key insight:** Inside a popup, `$TMUX_PANE` is the popup's own pane ID, not the pane that triggered the popup.

**Correct approach:** Capture it at bind time and pass via `-e`:

```bash
# In claude-prompts.tmux:
tmux bind-key -T "$table" "$key" \
  run-shell "'$SCRIPTS_DIR/popup.sh' '#{pane_id}'"
```

`#{pane_id}` is evaluated by tmux when the key is pressed (not at bind time). It expands to the ID of the pane that had focus when the key was pressed (e.g. `%3`).

Inside `popup.sh`:
```bash
ORIG_PANE="$1"   # e.g. %3
tmux display-popup -E \
  -e "ORIG_PANE=$ORIG_PANE" \
  -w 80% -h 70% \
  -T " Claude Prompts " \
  "$SCRIPTS_DIR/bin/claude-prompts"
```

Inside `bin/claude-prompts` (the TUI):
```bash
# $ORIG_PANE is set via -e
# After selection:
"$SCRIPTS_DIR/send-to-pane.sh" "$ORIG_PANE" "$selected_text"
```

---

## 5. Detecting Current Project (Originating Pane's PWD)

**Verified format variable:** `pane_current_path` — "Current path if available" (man page).

```bash
# Get the originating pane's working directory
orig_path=$(tmux display -p -t "$ORIG_PANE" '#{pane_current_path}')
```

This works from inside the popup because we pass `$ORIG_PANE` and query it via `tmux display`.

Used to scope the prompt list to the current project:
```bash
# In the TUI script:
orig_path=$(tmux display -p -t "$ORIG_PANE" '#{pane_current_path}')
# Filter history.jsonl to entries where .project matches or starts with $orig_path
```

**Pitfall:** `pane_current_path` tracks the shell's CWD at last prompt, not necessarily the process's real CWD. Good enough for our project-scoping use case.

---

## 6. Standalone Fallback (Running Outside Tmux)

Detect tmux by checking `$TMUX`:
```bash
if [ -z "$TMUX" ]; then
  STANDALONE=1
fi
```

`$TMUX` is set to the socket path when inside a tmux session, empty otherwise.

### Standalone behavior

When not in tmux, the tool should still open the TUI (in the current terminal), but instead of `paste-buffer`, copy to clipboard:

```bash
# send-to-pane.sh fallback:
if [ -z "$ORIG_PANE" ] || [ -z "$TMUX" ]; then
  # Clipboard fallback — priority order
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$text" | xsel --clipboard --input
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$text" | clip.exe   # WSL
  fi
  echo "Copied to clipboard." >&2
  exit 0
fi
```

The environment is WSL2 (per the project context), so `clip.exe` and possibly `wl-copy` should be prioritized. The above priority order handles all major platforms.

---

## 7. Plugin Lifecycle and Dev DX

### File location

TPM clones plugins to `~/.tmux/plugins/<repo-name>/`. For dev:
```bash
ln -sf /opt/development/tmux-claude-prompts ~/.tmux/plugins/tmux-claude-prompts
```

The `.tmux` file must be executable:
```bash
chmod +x /opt/development/tmux-claude-prompts/claude-prompts.tmux
```

### Adding to tmux.conf for dev

```tmux
# ~/.tmux.conf
set -g @plugin 'tmux-plugins/tpm'
# ... other plugins ...
# Dev: load directly (comment out for prod TPM install)
run-shell ~/.tmux/plugins/tmux-claude-prompts/claude-prompts.tmux
```

Or use the TPM symlink approach and let TPM source it normally.

### Reload during development

```bash
tmux source ~/.tmux.conf
# or bind a reload key:
bind-key r source-file ~/.tmux.conf \; display-message "Config reloaded"
```

### Nothing needs to "live in" the plugins dir

All runtime paths are computed relative to `BASH_SOURCE[0]` in the `.tmux` file. The symlink approach works perfectly.

---

## Recommended Approach for This Plugin

### Entrypoint: `claude-prompts.tmux`

```bash
#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"

key=$(get_option "@claude_prompts_key" "M-p")
table=$(get_option "@claude_prompts_key_table" "root")

tmux bind-key -T "$table" "$key" \
  run-shell "'$SCRIPTS_DIR/popup.sh' '#{pane_id}'"
```

**Default key: `M-p` (Alt+P) in root table — no prefix required.**

### `scripts/popup.sh`

```bash
#!/usr/bin/env bash
ORIG_PANE="${1:-%0}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_PATH=$(tmux display -p -t "$ORIG_PANE" '#{pane_current_path}' 2>/dev/null || echo "$HOME")

tmux display-popup \
  -E \
  -w 80% \
  -h 75% \
  -b rounded \
  -T " 󰭻 Claude Prompts " \
  -e "ORIG_PANE=$ORIG_PANE" \
  -e "ORIG_PATH=$ORIG_PATH" \
  -d "$ORIG_PATH" \
  "$CURRENT_DIR/../bin/claude-prompts"
```

### `scripts/send-to-pane.sh`

```bash
#!/usr/bin/env bash
ORIG_PANE="$1"
TEXT="$2"

if [ -n "$ORIG_PANE" ] && [ -n "$TMUX" ]; then
  tmux set-buffer -- "$TEXT"
  tmux paste-buffer -p -t "$ORIG_PANE"
else
  # Standalone / clipboard fallback
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$TEXT" | clip.exe
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$TEXT" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$TEXT" | xclip -selection clipboard
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$TEXT" | pbcopy
  fi
fi
```

### `scripts/helpers.sh`

```bash
#!/usr/bin/env bash
get_option() {
  local option="$1"
  local default="$2"
  local value
  value=$(tmux show-option -gqv "$option" 2>/dev/null)
  echo "${value:-$default}"
}

tmux_version_ge() {
  [ "$(printf '%s\n' "$1" "$(tmux -V | cut -d' ' -f2)" | sort -V | head -1)" = "$1" ]
}
```

---

## File Skeleton

```
tmux-claude-prompts/
├── claude-prompts.tmux          # TPM entrypoint (chmod +x)
├── scripts/
│   ├── helpers.sh               # get_option(), version checks, clipboard detection
│   ├── popup.sh                 # launches display-popup, passes ORIG_PANE
│   └── send-to-pane.sh         # set-buffer + paste-buffer, or clipboard fallback
├── bin/
│   └── claude-prompts           # main TUI (bash + fzf or custom; receives ORIG_PANE/ORIG_PATH env)
├── tests/
│   └── *.bats                   # bats test files
└── README.md
```

---

## Pitfalls Checklist

1. **`$TMUX_PANE` inside popup is NOT the originating pane.** Always capture `#{pane_id}` at bind time and pass via `-e` or as an argument to `run-shell`.

2. **`#{pane_id}` in `bind-key` vs `run-shell`:** When you write `run-shell "'script.sh' '#{pane_id}'"`, tmux expands `#{pane_id}` before passing to the shell. The quotes must be correct — single-quote the script path, double-quote the whole run-shell argument.

3. **Bracketed paste:** Use `paste-buffer -p` (not `send-keys -l`) so Claude Code's readline interface handles multi-line prompts correctly.

4. **Border eats screen real estate:** `-w 80% -h 75%` with a rounded border gives the interior ~78% × 73%. Size picker UI accordingly.

5. **Escape key exits popup unconditionally.** fzf by default binds Escape to cancel. That's fine — users expect it. Just don't try to capture Escape for search-clear inside the TUI.

6. **Multi-line text in `send-keys -l`:** Newlines in send-keys are sent as actual newlines (Enter keypresses), which may submit the prompt prematurely. Use `paste-buffer -p` (bracketed paste) instead — Claude Code handles it correctly.

7. **`run-shell` quoting:** When the path contains spaces, the quoting inside `run-shell` must use proper shell quoting. The extrakto pattern `run-shell "\"$path\" \"#{pane_id}\""` is reliable.

8. **TPM executes `.tmux` files as executables** (not `source`). The file needs a proper shebang and `chmod +x`.

9. **User option reads must happen at startup:** `get_option` calls `tmux show-option`, which requires a running tmux server. The `.tmux` entrypoint runs after the server is up — safe. Avoid calling at bind time inside a `run-shell` unless tmux is guaranteed running.

10. **Standalone mode:** When `$TMUX` is empty, skip all `tmux` commands. The TUI binary should still open in the current terminal and copy to clipboard on selection.

---

## Key Sources

- `tmux(1)` man page, sections: `display-popup`, `bind-key`, `send-keys`, `paste-buffer`, `load-buffer`, `run-shell`, FORMATS table (`pane_id`, `pane_current_path`, `TMUX_PANE`)
- **tmux-yank** (`tmux-plugins/tmux-yank`): canonical `helpers.sh` pattern, `get_option()`, clipboard detection priority
- **extrakto** (`laktak/extrakto`): `#{pane_id}` passing pattern, popup invocation with `-e`, `set-buffer + paste-buffer -p` send-back mechanism (in `extrakto_plugin.py`)
- TPM `scripts/source_plugins.sh`: executes `*.tmux` as a shell executable, not sourced
- TPM `docs/how_to_create_plugin.md`: file structure and naming conventions
