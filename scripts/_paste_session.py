#!/usr/bin/env python3
"""_paste_session.py — shared helpers for recovering paste bodies from
session JSONL files when `~/.claude/history.jsonl` records carry an
empty `pastedContents:{}` (current Claude Code format).

Stdlib-only. Used by extract_session_pastes.py and backfill_session_pastes.py.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

# Tolerance for matching a session-file user message to a history entry by
# timestamp. Two seconds covers normal write-jitter between the two files.
MATCH_TOLERANCE_MS = 2000

# A paste-cache hash should be a short hex string (Claude Code emits 16-char
# hex digests). Anything outside [0-9a-f] is rejected — defends against any
# attempt to smuggle path traversal via `contentHash`.
_HASH_RX = re.compile(r"^[0-9a-fA-F]{1,64}$")


def read_paste_cache(home: Path, content_hash: str) -> str | None:
    """Read `$HOME/.claude/paste-cache/<content_hash>.txt`.

    Returns the file contents as a string, or None on any failure
    (missing file, unreadable, or unsafe `content_hash`).
    """
    if not isinstance(content_hash, str) or not content_hash:
        return None
    if not _HASH_RX.match(content_hash):
        return None
    path = home / ".claude" / "paste-cache" / f"{content_hash}.txt"
    # Belt-and-suspenders containment check.
    cache_root = (home / ".claude" / "paste-cache").resolve()
    try:
        resolved = path.resolve()
    except OSError:
        return None
    if not resolved.is_relative_to(cache_root):
        return None
    if not path.is_file():
        return None
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

# Splits a display string on `[Pasted text #N]` (with optional " +K lines").
# Capture group 1 is the paste id. Result alternates [seg, id, seg, id, ..., seg].
PASTE_SPLIT_RX = re.compile(r"\[Pasted text #(\d+)(?: \+\d+ lines)?\]")


def sanitize_project(project: str) -> str:
    """`/opt/development/playbook` → `-opt-development-playbook`.

    Every `/` (including the leading one) becomes `-`. This is the
    convention Claude Code uses for `~/.claude/projects/<sanitized>/`.
    """
    sanitized = project.replace("/", "-")
    # Refuse pure-empty or dot-only project values to avoid path traversal
    # when constructing $HOME/.claude/projects/<sanitized>/<session>.jsonl.
    if not sanitized or sanitized.strip("-.") == "":
        return "_invalid_project_"
    return sanitized


def session_file_path(home: Path, project: str, session_id: str) -> Path:
    return home / ".claude" / "projects" / sanitize_project(project) / f"{session_id}.jsonl"


def parse_iso_to_ms(ts: str) -> int | None:
    """Parse an ISO-8601 timestamp string to ms-since-epoch, or None."""
    if not ts:
        return None
    # `datetime.fromisoformat` doesn't accept trailing 'Z' before Python 3.11.
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return None
    return int(dt.timestamp() * 1000)


def normalize_message_content(content) -> str | None:
    """`message.content` may be a string or a list of blocks.

    For list form, concatenate the `text` field of every `type=="text"`
    block in order. Returns None if neither shape applies.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text")
                if isinstance(t, str):
                    parts.append(t)
        return "".join(parts)
    return None


def load_session_user_messages(path: Path, target_ms: int) -> list[tuple[int, str]]:
    """Read `path` line-by-line, return [(ts_ms, content), ...] for every
    user message within MATCH_TOLERANCE_MS of `target_ms`, sorted by
    closeness to `target_ms` (ascending |delta|)."""
    out: list[tuple[int, str]] = []
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
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") != "user":
                continue
            if rec.get("isMeta") is True:
                continue
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            ts_str = rec.get("timestamp")
            ts_ms = parse_iso_to_ms(ts_str) if isinstance(ts_str, str) else None
            if ts_ms is None:
                continue
            if abs(ts_ms - target_ms) > MATCH_TOLERANCE_MS:
                continue
            content = normalize_message_content(msg.get("content"))
            if content is None:
                continue
            out.append((ts_ms, content))
    out.sort(key=lambda pair: abs(pair[0] - target_ms))
    return out


def split_display(display: str) -> tuple[list[str], list[int]]:
    """Returns (segments, ids). Segments has len == K+1 where K = len(ids)."""
    parts = PASTE_SPLIT_RX.split(display)
    # Pattern alternates: seg, id, seg, id, ..., seg.
    # `re.split` with one group yields exactly that.
    segments: list[str] = []
    ids: list[int] = []
    for i, p in enumerate(parts):
        if i % 2 == 0:
            segments.append(p)
        else:
            ids.append(int(p))
    return segments, ids


def extract_bodies(session_content: str, segments: list[str]) -> list[str] | None:
    """Walk segments left-to-right against `session_content`, peeling off
    each paste body between consecutive segments.

    Returns the recovered bodies in order, or None if extraction fails.
    """
    K = len(segments) - 1
    if K <= 0:
        return None

    bodies: list[str] = []
    remaining = session_content

    # Step 1: consume the leading segment (segments[0]).
    leading = segments[0]
    if leading != "":
        idx = remaining.find(leading)
        if idx != 0:
            return None
        remaining = remaining[len(leading):]
    # else: empty leading segment — body 0 starts at position 0.

    # Step 2: for each body i in 0..K-1, extract until the next
    # non-empty segment delimiter (or to end of string if all remaining
    # segments are empty, i.e. body extends to EOS).
    for i in range(K):
        # Find the next non-empty segment among segments[i+1 .. K]
        next_nonempty_idx = None
        for j in range(i + 1, K + 1):
            if segments[j] != "":
                next_nonempty_idx = j
                break

        if next_nonempty_idx is None:
            # No more delimiters — final body extends to end of string.
            # But: this only consumes body i; if there are bodies after
            # i (i.e. i < K-1), they get an empty share. That's a failure
            # mode because we cannot disambiguate. Bail.
            if i != K - 1:
                return None
            bodies.append(remaining)
            remaining = ""
            continue

        delim = segments[next_nonempty_idx]
        pos = remaining.find(delim)
        if pos < 0:
            return None
        body = remaining[:pos]
        bodies.append(body)
        remaining = remaining[pos + len(delim):]

        # If next_nonempty_idx > i+1, those intermediate empty segments
        # mean bodies i+1 .. next_nonempty_idx-1 are sandwiched between
        # the same delimiters with no text between them. We can only
        # extract them if there's content between consecutive markers in
        # the source; since segments are empty here, the user actually
        # pasted bodies back-to-back with no separator. We cannot split
        # them unambiguously. Bail.
        if next_nonempty_idx > i + 1:
            return None

    if len(bodies) != K:
        return None
    return bodies


def recover_pastes(
    home: Path,
    project: str,
    session_id: str,
    target_ms: int,
    display: str,
) -> list[tuple[int, str]] | None:
    """Top-level recovery: returns [(paste_id, body), ...] or None on failure.

    None on:
      - missing session file
      - no markers in display
      - no candidate user message matched
      - all candidates failed extraction
    """
    segments, ids = split_display(display)
    if not ids:
        return None

    path = session_file_path(home, project, session_id)
    # Belt-and-suspenders: even after sanitize_project, ensure the resolved
    # path lives under $HOME/.claude/projects/. Refuses any session_id or
    # project that smuggled in `..` or absolute-path components.
    projects_root = (home / ".claude" / "projects").resolve()
    try:
        resolved = path.resolve()
    except OSError:
        return None
    if not resolved.is_relative_to(projects_root):
        return None
    if not path.is_file():
        return None

    candidates = load_session_user_messages(path, target_ms)
    if not candidates:
        return None

    for _ts, content in candidates:
        bodies = extract_bodies(content, segments)
        if bodies is None:
            continue
        return list(zip(ids, bodies))

    return None
