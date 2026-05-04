#!/usr/bin/env python3
"""rebuild_previews.py — rebuild display_preview for every existing prompt.

Used by the v2 → v3 schema migration: display_preview now inlines paste
content (and substitutes `[Pasted Text Lost]` for missing pastes) rather
than carrying raw `[Pasted text #N]` markers, so already-ingested rows
need their preview field rewritten.

Stdlib-only — no venv, no extension. Reads $CP_DB from the environment.
"""

from __future__ import annotations

import os
import re
import sqlite3
import sys

PASTE_RX = re.compile(r"\[Pasted text #(\d+)( \+\d+ lines)?\]")
LOST_LABEL = "[Pasted Text Lost]"


def main() -> int:
    db_path = os.environ.get("CP_DB")
    if not db_path or not os.path.isfile(db_path):
        return 0  # nothing to rebuild

    db = sqlite3.connect(db_path, timeout=10.0)
    db.row_factory = sqlite3.Row

    pastes: dict[tuple[int, int], str] = {}
    for r in db.execute(
        "SELECT prompt_id, paste_id, content FROM paste_contents WHERE content IS NOT NULL AND content <> ''"
    ):
        pastes[(r["prompt_id"], r["paste_id"])] = r["content"]

    updates: list[tuple[str, int]] = []
    for r in db.execute("SELECT id, display_full FROM prompts"):
        prompt_id = r["id"]
        text = r["display_full"] or ""

        def sub(m: re.Match) -> str:
            paste_id = int(m.group(1))
            return pastes.get((prompt_id, paste_id)) or LOST_LABEL

        resolved = PASTE_RX.sub(sub, text)
        updates.append((resolved.replace("\n", " ↵ "), prompt_id))

    with db:
        db.executemany(
            "UPDATE prompts SET display_preview = ? WHERE id = ?", updates
        )

    sys.stderr.write(f"rebuild_previews.py: rewrote {len(updates)} rows\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
