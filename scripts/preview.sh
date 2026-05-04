#!/usr/bin/env bash
# preview.sh — render preview pane content for a prompt id.
# Usage: preview.sh <id>   Reads $FZF_PREVIEW_COLUMNS (default 80).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/glyphs.sh"

require_dep sqlite3

id="${1:-}"
if [ -z "$id" ] || ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
  printf 'preview.sh: invalid id: %s\n' "$id" >&2; exit 1
fi
ensure_db

cols="${FZF_PREVIEW_COLUMNS:-80}"
[ "${GLYPHS[trunc]}" = "..." ] && FENCE_CHAR="-" || FENCE_CHAR="─"

# Pre-build full-width fence
FENCE_FOOTER=""
for (( i=0; i<cols; i++ )); do FENCE_FOOTER="${FENCE_FOOTER}${FENCE_CHAR}"; done

display_tmp="$(mktemp /tmp/cp_preview_display_XXXXXX)"
paste_tmp="$(mktemp /tmp/cp_preview_paste_XXXXXX)"
trap 'rm -f "$display_tmp" "$paste_tmp"' EXIT

project="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT project FROM prompts WHERE id=${id};" 2>/dev/null)"
ts="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT ts FROM prompts WHERE id=${id};" 2>/dev/null)"
[ -z "$ts" ] && { printf '(prompt not found)\n'; exit 0; }

sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT display_full FROM prompts WHERE id=${id};" 2>/dev/null > "$display_tmp"
paste_count="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" "SELECT count(*) FROM paste_contents WHERE prompt_id=${id};" 2>/dev/null || printf '0')"

# Write paste records: \x01\x02\x03<pid>\x03<type>\x03<content> per paste
paste_ids="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
  "SELECT paste_id FROM paste_contents WHERE prompt_id=${id} ORDER BY paste_id;" 2>/dev/null || true)"
for pid in $paste_ids; do
  ptype="$(sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT type FROM paste_contents WHERE prompt_id=${id} AND paste_id=${pid};" 2>/dev/null)"
  printf '\x01\x02\x03%s\x03%s\x03' "$pid" "$ptype"
  sqlite3 -cmd ".timeout 3000" "$CP_DB" \
    "SELECT content FROM paste_contents WHERE prompt_id=${id} AND paste_id=${pid};" 2>/dev/null
done > "$paste_tmp"

awk \
  -v cols="$cols" -v fc="$FENCE_CHAR" -v ff="$FENCE_FOOTER" \
  -v mpl=500 -v pf="$paste_tmp" -v df="$display_tmp" \
'
function wrap_text(s, w,    res, cur, wds, n, i, wd) {
  res=""; cur=""; n=split(s,wds," ")
  for(i=1;i<=n;i++){wd=wds[i]; if(cur=="")cur=wd; else if(length(cur)+1+length(wd)<=w)cur=cur" "wd; else{res=res cur"\n";cur=wd}}
  return res (cur!=""?cur:"")
}
function wrap_block(s, w,    ls, n, i, out) {
  out=""; n=split(s,ls,"\n")
  for(i=1;i<=n;i++) out=out wrap_text(ls[i],w)"\n"
  return out
}
BEGIN {
  RS="\001\002\003"; FS="\003"
  while((getline < pf)>0){
    if(NF<3)continue
    pid=$1; ptype=$2; pcont=$3
    sub(/\n$/,"",pid); sub(/\n$/,"",pcont)
    if(pid!=""){pc[pid]=pcont; pt[pid]=ptype}
  }
  close(pf); RS="\n"; FS=" "
  txt=""; first=1
  while((getline line < df)>0){if(!first)txt=txt"\n"; txt=txt line; first=0}
  close(df)
  out=""; sf=1; tl=length(txt)
  while(sf<=tl){
    p=index(substr(txt,sf),"[Pasted text #")
    if(!p){rem=substr(txt,sf); if(rem!="")out=out wrap_block(rem,cols); break}
    ap=sf+p-1; rest=substr(txt,ap)
    pre=substr(txt,sf,ap-sf); if(pre!="")out=out wrap_block(pre,cols)
    if(match(rest,/^\[Pasted text #([0-9]+)( \+[0-9]+ lines)?\]/,m)){
      pid=m[1]; fm=m[0]
      if(pid in pc){
        cont=pc[pid]; n=split(cont,cl,"\n")
        lbl=fc fc fc " pasted #" pid " (" pt[pid] ", " n " lines) "
        fill=cols-length(lbl)-1; if(fill<0)fill=0
        for(k=0;k<fill;k++)lbl=lbl fc
        out=out lbl"\n"
        shown=(n>mpl)?mpl:n
        for(k=1;k<=shown;k++)out=out cl[k]"\n"
        if(n>mpl)out=out "... (truncated, "(n-mpl)" more lines)\n"
        out=out ff"\n"
      } else {
        # Marker without stored content — flag visibly in red.
        out=out "\033[1;38;5;196m" fm " (no stored content)\033[0m"
      }
      sf=ap+length(fm)
    } else {out=out substr(txt,ap,1); sf=ap+1}
  }
  printf "%s",out
}
'

# Metadata footer
NOW_MS="$(now_ms)"; age_ms=$(( NOW_MS - ts ))
if   [ "$age_ms" -lt 60000 ];       then rel_time="just now"
elif [ "$age_ms" -lt 3600000 ];     then rel_time="$(( age_ms/60000 ))m ago"
elif [ "$age_ms" -lt 86400000 ];    then rel_time="$(( age_ms/3600000 ))h ago"
elif [ "$age_ms" -lt 604800000 ];   then rel_time="$(( age_ms/86400000 ))d ago"
elif [ "$age_ms" -lt 2592000000 ];  then rel_time="$(( age_ms/604800000 ))w ago"
elif [ "$age_ms" -lt 31536000000 ]; then rel_time="$(( age_ms/2592000000 ))mo ago"
else rel_time="$(( age_ms/31536000000 ))y ago"; fi

line_count="$(awk 'END{print NR}' "$display_tmp")"
project_base=""; [ -n "$project" ] && project_base="$(basename "$project")"

printf '\n%s\n' "$FENCE_FOOTER"
printf '%s\n' "${project_base} · ${rel_time} · ${line_count} lines · ${paste_count} pastes"
