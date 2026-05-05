#!/usr/bin/env bash
# ingest.sh — incremental upsert from history.jsonl into the prompts DB.
#
# Hash strategy: sha1(display_full + 0x1f + project) computed via
# `printf '%s\x1f%s' "$display_full" "$project" | sha1sum` per record.
# For 12k rows this is ~12k subshells but each is trivial; total time is
# dominated by sqlite3 batch I/O, not sha1sum. Documented per blueprint §4.
#
# Paste inserts use hash-based lookup rather than RETURNING id, which would
# require row-by-row sqlite3 calls. Instead, each paste row does:
#   INSERT INTO paste_contents SELECT (SELECT id FROM prompts WHERE hash=?), ...
# This keeps all DML in a single temp-file batch fed to sqlite3 once per chunk.
#
# Exit codes: 0 success, 1 dep missing, 2 sql error.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3
require_dep jq
require_dep sha1sum

FORCE=0
HISTORY_FILE=""

# Parse CLI args
while [ $# -gt 0 ]; do
  case "$1" in
    --force)      FORCE=1 ;;
    --from-file)  shift; HISTORY_FILE="$1" ;;
    *)            printf 'ingest.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

[ -z "$HISTORY_FILE" ] && HISTORY_FILE="$CP_HISTORY"

ensure_db

# --- Read current byte offset from DB ---
current_offset="$(sqlite3 "$CP_DB" \
  "SELECT COALESCE((SELECT value FROM ingest_state WHERE key='byte_offset'), '0');" \
  2>/dev/null || printf '0')"
current_offset="${current_offset:-0}"

# --- Get file size ---
if [ ! -f "$HISTORY_FILE" ]; then
  printf 'ingest.sh: history file not found: %s\n' "$HISTORY_FILE" >&2
  exit 0
fi
file_size="$(stat -c %s "$HISTORY_FILE" 2>/dev/null || printf '0')"

# Handle truncation/rotation
if [ "$current_offset" -gt "$file_size" ]; then
  current_offset=0
fi

# Fast path: nothing new and not forced
if [ "$current_offset" -eq "$file_size" ] && [ "$FORCE" -eq 0 ]; then
  exit 0
fi

# On --force, re-read from beginning but keep existing rows (UPSERT reconciles)
[ "$FORCE" -eq 1 ] && current_offset=0

start_ms="$(now_ms)"

# --- Stream new bytes through jq ---
# jq emits one JSON object per source field we care about, one line each.
# We use a flat object with a "kind" discriminator:
#   kind=prompt → display, project, ts, hash_input (we compute hash in bash)
#   kind=paste  → paste_id, type, content (associated with the preceding prompt)
#
# We read jq output line by line in bash, grouping paste records after
# their parent prompt record.

BATCH_SIZE=500
batch_num=0
prompt_count=0
paste_count=0

# Temp file for batched SQL statements
sql_tmp="$(mktemp /tmp/cp_ingest_XXXXXX.sql)"
trap 'rm -f "$sql_tmp"' EXIT

# Whether this run started from offset 0 (for the optimize step)
started_from_zero=0
[ "$current_offset" -eq 0 ] && started_from_zero=1

# We track the current hash and per-prompt buffered paste data.
# Pastes for a source line arrive BEFORE its prompt; bash buffers them
# in associative arrays so display_preview can substitute the marker.
current_hash=""
declare -A pending_paste_content=()
declare -A pending_paste_type=()

clear_pending_pastes() {
  pending_paste_content=()
  pending_paste_type=()
}

# resolve_display <display_full> → echoes display_full with every
# [Pasted text #N (+M lines)?] marker replaced by the paste content from
# pending_paste_content. Markers whose paste is missing (or has empty
# content) become the literal string "[Pasted Text Lost]" — the user never
# sees a raw marker.
resolve_display() {
  local text="$1"
  local out="" full pid before after
  while [[ "$text" =~ \[Pasted\ text\ \#([0-9]+)(\ \+[0-9]+\ lines)?\] ]]; do
    full="${BASH_REMATCH[0]}"
    pid="${BASH_REMATCH[1]}"
    before="${text%%"$full"*}"
    after="${text#*"$full"}"
    out="${out}${before}"
    if [ -n "${pending_paste_content[$pid]:-}" ]; then
      out="${out}${pending_paste_content[$pid]}"
    else
      out="${out}[Pasted Text Lost]"
    fi
    text="$after"
  done
  out="${out}${text}"
  printf '%s' "$out"
}

# compute_preview <display_full> → list-row text. Always inlines paste
# content (so the user never sees a marker), then collapses newlines to '↵'.
# render.sh truncates to 500 chars at display time.
compute_preview() {
  local resolved="$(resolve_display "$1")"
  printf '%s' "${resolved//$'\n'/ ↵ }"
}

flush_batch() {
  if [ -s "$sql_tmp" ]; then
    if ! sqlite3 -bail "$CP_DB" < "$sql_tmp" >/dev/null 2>&1; then
      printf 'ingest.sh: sqlite3 error during batch %d\n' "$batch_num" >&2
      rm -f "$sql_tmp"
      exit 2
    fi
  fi
  # Clear the temp file for the next batch
  : > "$sql_tmp"
  batch_num=$((batch_num + 1))
}

# Write BEGIN to start the first transaction
printf 'BEGIN;\n' > "$sql_tmp"
prompts_in_batch=0

# Read jq output. We use `tail -c +N` to seek to byte offset.
# jq -c processes line by line from the partial file.
# We emit two kinds of records per source line (if applicable).
process_stream() {
  # tail byte offset: +1 means "from byte 1" (start), +N means "start at byte N"
  local seek_pos=$((current_offset + 1))
  # Emit pastes BEFORE the prompt for each source line so bash buffers all
  # paste content for a given prompt before computing display_preview.
  tail -c "+${seek_pos}" "$HISTORY_FILE" | jq -cR 'fromjson? |
    select(.display != null and .display != "") |
    ((.pastedContents // {}) | to_entries[] |
      # Claude Code emits two formats:
      #   inline:  .value.content  is the full paste body
      #   cached:  .value.contentHash points to ~/.claude/paste-cache/<hash>.txt
      # We surface both — the bash loop prefers `content`, falls back to
      # paste-cache lookup when only `content_hash` is set, and finally
      # falls back to session-JSONL recovery for genuinely-empty entries.
      select((.value.content != null and .value.content != "")
             or (.value.contentHash != null and .value.contentHash != "")) |
      {
        kind: "paste",
        paste_id: (.key | tonumber),
        type: (.value.type // "text"),
        content: (.value.content // ""),
        content_hash: (.value.contentHash // "")
      }
    ),
    {
      kind: "prompt",
      display: .display,
      project: (.project // ""),
      ts: ((.timestamp // 0) | if . == null then 0 else . end),
      session_id: (.sessionId // "")
    }
  ' 2>/dev/null
}

while IFS= read -r line; do
  kind="$(printf '%s' "$line" | jq -r '.kind' 2>/dev/null)"

  if [ "$kind" = "paste" ]; then
    # Buffer paste content; the prompt for this source line arrives next.
    paste_id="$(printf '%s' "$line" | jq -r '.paste_id')"
    paste_type="$(printf '%s' "$line" | jq -r '.type')"
    content="$(printf '%s' "$line" | jq -r '.content')"
    content_hash="$(printf '%s' "$line" | jq -r '.content_hash')"
    # Paste-cache fallback: when `content` is empty but `contentHash` is
    # set, the paste body lives at ~/.claude/paste-cache/<hash>.txt.
    # Validate the hash (hex, ≤64 chars) before constructing a path —
    # never substitute untrusted text into a shell-resolved file path.
    if [ -z "$content" ] && [ -n "$content_hash" ] && [ "$content_hash" != "null" ]; then
      if [[ "$content_hash" =~ ^[0-9a-fA-F]{1,64}$ ]]; then
        cache_file="${HOME}/.claude/paste-cache/${content_hash}.txt"
        if [ -f "$cache_file" ]; then
          content="$(cat "$cache_file" 2>/dev/null || printf '')"
        fi
      fi
    fi
    pending_paste_content[$paste_id]="$content"
    pending_paste_type[$paste_id]="$paste_type"

  elif [ "$kind" = "prompt" ]; then
    display_full="$(printf '%s' "$line" | jq -r '.display')"
    project="$(printf '%s' "$line" | jq -r '.project')"
    ts_ms="$(printf '%s' "$line" | jq -r '.ts')"
    ts="$ts_ms"
    session_id="$(printf '%s' "$line" | jq -r '.session_id')"

    # Session-file fallback: Claude Code now writes empty pastedContents:{}
    # in history.jsonl, so paste bodies must be recovered from the per-
    # session JSONL under ~/.claude/projects/<sanitized>/<session_id>.jsonl.
    # Fire whenever the prompt has paste markers AND nothing was buffered
    # (covers genuinely-empty pastedContents:{} and the rare case where
    # entries lack both `content` AND `contentHash`). Cache-miss entries
    # already populate the buffer with empty strings, so they correctly
    # bypass this branch and fall through to "[Pasted Text Lost]".
    if [ "${#pending_paste_content[@]}" -eq 0 ] \
        && [ -n "$session_id" ] \
        && [[ "$display_full" == *"[Pasted text #"* ]]; then
      while IFS= read -r pline; do
        [ -z "$pline" ] && continue
        rec_pid="$(printf '%s' "$pline" | jq -r '.paste_id' 2>/dev/null)"
        rec_type="$(printf '%s' "$pline" | jq -r '.type' 2>/dev/null)"
        rec_content="$(printf '%s' "$pline" | jq -r '.content' 2>/dev/null)"
        [ -z "$rec_pid" ] || [ "$rec_pid" = "null" ] && continue
        pending_paste_content[$rec_pid]="$rec_content"
        pending_paste_type[$rec_pid]="$rec_type"
      done < <(python3 "${SCRIPT_DIR}/extract_session_pastes.py" \
        --display "$display_full" \
        --project "$project" \
        --ts "$ts_ms" \
        --session-id "$session_id" 2>/dev/null)
    fi

    # Collapsed display (newlines → ' ↵ ')
    display="${display_full//$'\n'/ ↵ }"

    # display_preview: marker-only rows with stored content get a snippet;
    # everything else uses the collapsed display verbatim.
    preview="$(compute_preview "$display_full")"

    # sha1 of display_full + 0x1f + project
    current_hash="$(printf '%s\x1f%s' "$display_full" "$project" | sha1sum | cut -c1-40)"

    sq_display="${display//\'/\'\'}"
    sq_display_full="${display_full//\'/\'\'}"
    sq_preview="${preview//\'/\'\'}"
    sq_project="${project//\'/\'\'}"
    sq_hash="${current_hash//\'/\'\'}"

    # UPSERT prompt. On conflict update ts AND display_preview (pin state preserved).
    printf "INSERT INTO prompts(display, display_full, display_preview, project, ts, hash)\n" >> "$sql_tmp"
    printf "VALUES('%s', '%s', '%s', '%s', %s, '%s')\n" \
      "$sq_display" "$sq_display_full" "$sq_preview" "$sq_project" "$ts" "$sq_hash" >> "$sql_tmp"
    printf "ON CONFLICT(hash) DO UPDATE SET ts = MAX(prompts.ts, excluded.ts), display_preview = excluded.display_preview;\n" >> "$sql_tmp"

    prompt_count=$((prompt_count + 1))
    prompts_in_batch=$((prompts_in_batch + 1))

    # Emit paste INSERTs from the buffer for this prompt. Skip entries
    # whose body never resolved (paste-cache miss, etc.) — preview.sh
    # will render those markers as "[Pasted Text Lost]" instead.
    for pid in "${!pending_paste_content[@]}"; do
      pcontent="${pending_paste_content[$pid]}"
      [ -z "$pcontent" ] && continue
      ptype="${pending_paste_type[$pid]}"
      sq_pcontent="${pcontent//\'/\'\'}"
      sq_ptype="${ptype//\'/\'\'}"
      printf "INSERT INTO paste_contents(prompt_id, paste_id, type, content)\n" >> "$sql_tmp"
      printf "SELECT (SELECT id FROM prompts WHERE hash='%s'), %s, '%s', '%s'\n" \
        "$sq_hash" "$pid" "$sq_ptype" "$sq_pcontent" >> "$sql_tmp"
      printf "ON CONFLICT(prompt_id, paste_id) DO UPDATE SET type = excluded.type, content = excluded.content;\n" >> "$sql_tmp"
      paste_count=$((paste_count + 1))
    done

    # Reset buffer for the next source line.
    clear_pending_pastes

    if [ "$prompts_in_batch" -ge "$BATCH_SIZE" ]; then
      printf 'COMMIT;\n' >> "$sql_tmp"
      flush_batch
      printf 'BEGIN;\n' > "$sql_tmp"
      prompts_in_batch=0
    fi
  fi
done < <(process_stream)

# Flush the final batch
printf 'COMMIT;\n' >> "$sql_tmp"
flush_batch

# Update byte offset (only if no error — we exit 2 on error above)
sqlite3 -bail "$CP_DB" \
  "INSERT INTO ingest_state(key,value) VALUES('byte_offset','${file_size}')
   ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null

# Run FTS optimize on full re-ingest to compact the FTS index
if [ "$started_from_zero" -eq 1 ] && [ "$prompt_count" -gt 0 ]; then
  sqlite3 "$CP_DB" "INSERT INTO prompts_fts(prompts_fts) VALUES('optimize');" >/dev/null 2>&1 || true
fi

end_ms="$(now_ms)"
elapsed=$((end_ms - start_ms))

printf 'ingested %d new rows (%d paste rows) in %d ms\n' \
  "$prompt_count" "$paste_count" "$elapsed" >&2

# Note: embedding backfill is no longer driven from ingest.sh. The popup
# launcher fires `embed.sh kickoff &` in the background after ingest, so
# popup open is never blocked by model load or pip install.
