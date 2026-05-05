#!/usr/bin/env bash
# resolve.sh — replace [Pasted text #N( +M lines)?] markers with paste content.
# Usage: resolve.sh <id>
# Output: resolved display_full on stdout. Unmatched markers left intact.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3
: "${AWK:=awk}"

id="${1:-}"
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'resolve.sh: invalid id: %s\n' "$id" >&2; exit 1
fi

ensure_db

display_full="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT display_full FROM prompts WHERE id=${id};" 2>/dev/null)"
[ -z "$display_full" ] && exit 0

# Write display_full and paste rows to temp files
display_tmp="$(mktemp /tmp/cp_resolve_display_XXXXXX)"
paste_tmp="$(mktemp /tmp/cp_resolve_paste_XXXXXX)"
trap 'rm -f "$display_tmp" "$paste_tmp"' EXIT

printf '%s' "$display_full" > "$display_tmp"

# Format in paste_tmp: \x01\x02\x03<pid>\x03<content> per paste row.
# Build the sentinel format directly in SQL via GROUP_CONCAT so no row
# delimiter byte is required — paste content may contain ANY byte
# (including \x1e, \x1f, \n), so any external delimiter is unsafe.
sqlite3 -bail -cmd ".timeout 3000" "$CP_DB" \
  "SELECT GROUP_CONCAT(char(1)||char(2)||char(3)||paste_id||char(3)||content, '') FROM paste_contents WHERE prompt_id=${id} ORDER BY paste_id;" \
  2>/dev/null > "$paste_tmp"

awk -v paste_file="$paste_tmp" -v display_file="$display_tmp" '
function load_pastes(    raw, recs, n, i, rec, e1, pid, pcontent) {
  while ((getline line < paste_file) > 0) raw = raw line "\n"
  close(paste_file)
  n = split(raw, recs, "\001\002\003")
  for (i = 2; i <= n; i++) {
    rec = recs[i]; e1 = index(rec, "\003")
    if (!e1) continue
    pid = substr(rec, 1, e1-1); pcontent = substr(rec, e1+1)
    sub(/\n$/, "", pcontent)
    # Empty content = legacy hash-only ingest; treat as missing so it
    # becomes "[Pasted Text Lost]" rather than vanishing silently.
    if (pid != "" && pcontent != "") pastes[pid] = pcontent
  }
}
BEGIN {
  load_pastes()
  text = ""; first = 1
  while ((getline line < display_file) > 0) {
    if (!first) text = text "\n"; text = text line; first = 0
  }
  close(display_file)
  # Single-pass replace. NO recursion: paste bodies legitimately contain
  # marker-shaped substrings (e.g. hook errors that quote `[Pasted text #N ...]`),
  # so re-scanning the replacement would loop forever.
  new_text = ""; sf = 1; tl = length(text)
  while (sf <= tl) {
    p = index(substr(text, sf), "[Pasted text #")
    if (!p) { new_text = new_text substr(text, sf); break }
    ap = sf + p - 1
    new_text = new_text substr(text, sf, ap - sf)
    rest = substr(text, ap)
    if (match(rest, /^\[Pasted text #([0-9]+)( \+[0-9]+ lines)?\]/, m)) {
      pid = m[1]; fm = m[0]
      if (pid in pastes) new_text = new_text pastes[pid]
      else { new_text = new_text "[Pasted Text Lost]"; unmatched++ }
      sf = ap + length(fm)
    } else { new_text = new_text substr(text, ap, 1); sf = ap + 1 }
  }
  printf "%s", new_text
  exit (unmatched > 0 ? 2 : 0)
}
'
