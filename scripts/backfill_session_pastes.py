#!/usr/bin/env python3
"""backfill_session_pastes.py — v4 → v5 migration helper.

Walks every prompt row whose preview was previously rewritten as
"[Pasted Text Lost]" because the source `history.jsonl` entry had an
empty `pastedContents:{}` field. For each such row, find the matching
history entry, derive its session JSONL, recover paste bodies, and:
  1. INSERT OR REPLACE into paste_contents
  2. Rewrite display_preview using the same PASTE_RX substitution
     as rebuild_previews.py.

Stdlib-only. Idempotent: re-running is a no-op once the preview no
longer matches the LIKE filter.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from _paste_session import read_paste_cache, recover_pastes  # noqa: E402

PASTE_RX = re.compile(r"\[Pasted text #(\d+)( \+\d+ lines)?\]")
LOST_LABEL = "[Pasted Text Lost]"


def load_history(path: Path) -> list[dict]:
    out: list[dict] = []
    try:
        f = path.open("r", encoding="utf-8", errors="replace")
    except OSError:
        return out
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def find_history_entry(
    history: list[dict], project: str, ts_ms: int
) -> dict | None:
    # 1000ms is sufficient here: the DB ts IS the history.jsonl integer timestamp
    # (ingested verbatim), so real-world delta is always ~0ms.
    # (The session-JSONL ↔ history.jsonl match in _paste_session.py uses 2000ms
    # because two separate processes write those files.)
    best: dict | None = None
    best_delta = 1001  # strictly less than 1000ms tolerance below
    for rec in history:
        if rec.get("project") != project:
            continue
        rts = rec.get("timestamp")
        if not isinstance(rts, int):
            continue
        delta = abs(rts - ts_ms)
        if delta <= 1000 and delta < best_delta:
            best = rec
            best_delta = delta
    return best


def main() -> int:
    db_path = os.environ.get("CP_DB")
    if not db_path or not os.path.isfile(db_path):
        return 0

    home = Path(os.environ.get("HOME") or os.path.expanduser("~"))
    history_path = home / ".claude" / "history.jsonl"
    history = load_history(history_path)
    if not history:
        sys.stderr.write(
            "backfill_session_pastes.py: rewrote 0 of 0 lost-paste rows\n"
        )
        return 0

    db = sqlite3.connect(db_path, timeout=10.0)
    db.row_factory = sqlite3.Row

    rows = list(
        db.execute(
            "SELECT id, display_full, project, ts FROM prompts "
            "WHERE display_preview LIKE '%[Pasted Text Lost]%' "
            "AND display_full LIKE '%[Pasted text #%'"
        )
    )
    total = len(rows)
    rewritten = 0

    for r in rows:
        prompt_id = r["id"]
        display_full = r["display_full"] or ""
        project = r["project"] or ""
        ts_ms = int(r["ts"])

        entry = find_history_entry(history, project, ts_ms)
        if entry is None:
            continue

        bodies: list[tuple[int, str]] | None = None

        # Preferred path: history entry has `pastedContents` with `contentHash`
        # (or `content`) values. Recent Claude Code versions emit hash-only
        # entries; the body lives at ~/.claude/paste-cache/<hash>.txt.
        pc = entry.get("pastedContents")
        if isinstance(pc, dict) and len(pc) > 0:
            collected: list[tuple[int, str]] = []
            ok = True
            for key, val in pc.items():
                try:
                    paste_id = int(key)
                except (TypeError, ValueError):
                    ok = False
                    break
                if not isinstance(val, dict):
                    ok = False
                    break
                inline = val.get("content")
                if isinstance(inline, str) and inline != "":
                    collected.append((paste_id, inline))
                    continue
                content_hash = val.get("contentHash")
                if isinstance(content_hash, str) and content_hash:
                    body = read_paste_cache(home, content_hash)
                    if body is None:
                        ok = False
                        break
                    collected.append((paste_id, body))
                    continue
                # Entry has neither inline content nor contentHash — bail and
                # let the session-JSONL fallback try.
                sys.stderr.write(
                    f"backfill: prompt_id={prompt_id} has unresolvable "
                    f"paste entry, skipping inline path\n"
                )
                ok = False
                break
            if ok and collected:
                bodies = sorted(collected, key=lambda p: p[0])

        # Fallback: genuinely-empty `pastedContents:{}` — try the per-session
        # JSONL transcript.
        if bodies is None:
            session_id = entry.get("sessionId")
            if isinstance(session_id, str) and session_id:
                bodies = recover_pastes(
                    home=home,
                    project=project,
                    session_id=session_id,
                    target_ms=ts_ms,
                    display=display_full,
                )

        if not bodies:
            continue

        with db:
            for paste_id, content in bodies:
                db.execute(
                    "INSERT INTO paste_contents(prompt_id, paste_id, type, content) "
                    "VALUES(?, ?, 'text', ?) "
                    "ON CONFLICT(prompt_id, paste_id) DO UPDATE SET "
                    "type = excluded.type, content = excluded.content",
                    (prompt_id, paste_id, content),
                )

            # Rewrite preview using the same substitution scheme as
            # rebuild_previews.py.
            paste_map = {pid: body for pid, body in bodies}

            def sub(m: re.Match) -> str:
                pid = int(m.group(1))
                return paste_map.get(pid) or LOST_LABEL

            resolved = PASTE_RX.sub(sub, display_full)
            preview = resolved.replace("\n", " ↵ ")
            db.execute(
                "UPDATE prompts SET display_preview = ? WHERE id = ?",
                (preview, prompt_id),
            )

        rewritten += 1

    sys.stderr.write(
        f"backfill_session_pastes.py: rewrote {rewritten} of {total} lost-paste rows\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
