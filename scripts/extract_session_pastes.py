#!/usr/bin/env python3
"""extract_session_pastes.py — recover paste bodies for a single history
entry by reading the session JSONL file Claude Code keeps in
`~/.claude/projects/<sanitized-project>/<session_id>.jsonl`.

Invoked from ingest.sh per prompt that has empty `pastedContents:{}` but
markers in its display. On success prints one JSON line per body to
stdout: `{"paste_id":N,"type":"text","content":"..."}`. On any failure
exits 0 with no output — the caller falls back to the legacy
"[Pasted Text Lost]" path.

Stdlib-only — matches scripts/rebuild_previews.py style.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Add this script's directory so the shared helper imports cleanly even
# when invoked via an absolute path from bash.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from _paste_session import recover_pastes  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--display", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--ts", required=True)
    parser.add_argument("--session-id", required=True, dest="session_id")
    args = parser.parse_args()

    try:
        target_ms = int(args.ts)
    except ValueError:
        return 0

    home = Path(os.environ.get("HOME") or os.path.expanduser("~"))

    bodies = recover_pastes(
        home=home,
        project=args.project,
        session_id=args.session_id,
        target_ms=target_ms,
        display=args.display,
    )
    if not bodies:
        return 0

    for paste_id, content in bodies:
        sys.stdout.write(
            json.dumps(
                {"paste_id": paste_id, "type": "text", "content": content},
                ensure_ascii=False,
            )
            + "\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
