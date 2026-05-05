#!/usr/bin/env bash
# preview.sh — render preview pane content for a prompt id.
# Usage: preview.sh <id>   Reads $FZF_PREVIEW_COLUMNS (default 80).
#
# Pasted content is inlined transparently — the user never sees a raw
# `[Pasted text #N]` marker. Missing pastes become "[Pasted Text Lost]".
# A small metadata footer (project · age · lines · pastes) is appended.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"
. "${SCRIPT_DIR}/helpers.sh"

require_dep sqlite3

id="${1:-}"
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'preview.sh: invalid id: %s\n' "$id" >&2; exit 1
fi
ensure_db

cols="${FZF_PREVIEW_COLUMNS:-80}"
[ "${GLYPHS[trunc]}" = "..." ] && FENCE_CHAR="-" || FENCE_CHAR="─"

# Pre-build full-width fence for the metadata footer.
FENCE_FOOTER=""
for (( i=0; i<cols; i++ )); do FENCE_FOOTER="${FENCE_FOOTER}${FENCE_CHAR}"; done

project="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT project FROM prompts WHERE id=${id};" 2>/dev/null)"
ts="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT ts FROM prompts WHERE id=${id};" 2>/dev/null)"
[ -z "$ts" ] && { printf '(prompt not found)\n'; exit 0; }

paste_count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT count(*) FROM paste_contents WHERE prompt_id=${id};" 2>/dev/null || printf '0')"
line_count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT length(display_full) - length(replace(display_full, char(10), '')) + 1 FROM prompts WHERE id=${id};" 2>/dev/null || printf '0')"

# Body: resolve.sh inlines pastes (or "[Pasted Text Lost]" for missing),
# then awk wraps each line at $cols chars.
body="$("${SCRIPT_DIR}/resolve.sh" "$id" 2>/dev/null || true)"
printf '%s' "$body" | awk -v w="$cols" '
function wrap_text(s, w,    res, cur, wds, n, i, wd) {
  res=""; cur=""; n=split(s,wds," ")
  for(i=1;i<=n;i++){wd=wds[i]; if(cur=="")cur=wd; else if(length(cur)+1+length(wd)<=w)cur=cur" "wd; else{res=res cur"\n";cur=wd}}
  return res (cur!=""?cur:"")
}
{ print wrap_text($0, w) }
'

# Metadata footer.
NOW_MS="$(now_ms)"; age_ms=$(( NOW_MS - ts ))
if   [ "$age_ms" -lt 60000 ];       then rel_time="just now"
elif [ "$age_ms" -lt 3600000 ];     then rel_time="$(( age_ms/60000 ))m ago"
elif [ "$age_ms" -lt 86400000 ];    then rel_time="$(( age_ms/3600000 ))h ago"
elif [ "$age_ms" -lt 604800000 ];   then rel_time="$(( age_ms/86400000 ))d ago"
elif [ "$age_ms" -lt 2592000000 ];  then rel_time="$(( age_ms/604800000 ))w ago"
elif [ "$age_ms" -lt 31536000000 ]; then rel_time="$(( age_ms/2592000000 ))mo ago"
else rel_time="$(( age_ms/31536000000 ))y ago"; fi

project_base=""; [ -n "$project" ] && project_base="$(basename "$project")"

# Optional label appended to the metadata footer.
label="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT COALESCE(label, '') FROM prompts WHERE id=${id};" 2>/dev/null || true)"
label_suffix=""
if [ -n "$label" ]; then
  label_suffix=" · Label: ${label}"
fi

printf '\n%s\n' "$FENCE_FOOTER"
printf '%s\n' "${project_base} · ${rel_time} · ${line_count} lines · ${paste_count} pastes${label_suffix}"
