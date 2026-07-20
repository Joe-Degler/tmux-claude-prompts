#!/usr/bin/env python3
"""Incremental ingest of Claude Code session transcripts into the session tables.

Reads ~/.claude/projects/*/*.jsonl (one level deep) and indexes dialogue text
(user prompts, assistant text, !-bash inputs) per session. Tool calls are kept
as compact preview-only rows (role 'tool') and never enter session_fts.

Cursor contract (session_files): `offset` only ever points just past a
newline-terminated record, reads are bounded by the stat size taken before
reading, and messages + session aggregates + FTS body + cursor commit in one
transaction per file. A partially written final line is re-read next run.

Env: CP_DB (required), CP_PROJECTS_DIR (default $HOME/.claude/projects),
CP_RUN_DIR (lock + status files). Usage: ingest_sessions.py [--force]
"""

import fcntl
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

MAX_MSG_BYTES = 16 * 1024
MAX_BODY_BYTES = 2 * 1024 * 1024
MAX_TITLE_CHARS = 120
MAX_TOOL_ARG_CHARS = 100
FP_BYTES = 4096

# Strip C0 controls (incl. ESC, \x1e, \x1f) except \n and \t.
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

SKIP_PREFIXES = (
    "<local-command-",
    "<command-",
    "<bash-stdout",
    "<bash-stderr",
)
BASH_INPUT_RE = re.compile(r"^<bash-input>(.*?)</bash-input>\s*$", re.DOTALL)

# Cheap pre-filter: lines without these markers can't produce messages.
PREFILTER = (b'"type":"user"', b'"type":"assistant"')


def sanitize(text):
    text = CONTROL_RE.sub("", text)
    if len(text.encode("utf-8", "ignore")) > MAX_MSG_BYTES:
        text = text.encode("utf-8", "ignore")[:MAX_MSG_BYTES].decode("utf-8", "ignore")
    return text.strip()


def parse_ts(value, fallback):
    if isinstance(value, str):
        try:
            s = value.replace("Z", "+00:00")
            return int(datetime.fromisoformat(s).astimezone(timezone.utc).timestamp() * 1000)
        except ValueError:
            pass
    return fallback


def tool_one_liner(block):
    name = block.get("name") or "tool"
    inp = block.get("input") or {}
    arg = ""
    if isinstance(inp, dict):
        for key in ("command", "file_path", "description", "prompt", "pattern", "query"):
            val = inp.get(key)
            if isinstance(val, str) and val.strip():
                arg = val.strip().splitlines()[0]
                break
    if len(arg) > MAX_TOOL_ARG_CHARS:
        arg = arg[:MAX_TOOL_ARG_CHARS]
    return "{}: {}".format(name, arg) if arg else str(name)


def extract_user(record):
    """Yield (role, text) for a user record, or nothing if it's noise."""
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        content = "\n".join(p for p in parts if p)
    if not isinstance(content, str):
        return
    stripped = content.lstrip()
    m = BASH_INPUT_RE.match(stripped)
    if m:
        text = sanitize(m.group(1))
        if text:
            yield ("bash", text)
        return
    if any(stripped.startswith(p) for p in SKIP_PREFIXES):
        return
    text = sanitize(content)
    if text:
        yield ("user", text)


def extract_assistant(record):
    """Yield (role, text) preserving content[] order; adjacent text coalesced."""
    content = (record.get("message") or {}).get("content")
    if not isinstance(content, list):
        return
    pending_text = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            t = block.get("text", "")
            if t and t.strip():
                pending_text.append(t)
        elif btype == "tool_use":
            if pending_text:
                text = sanitize("\n".join(pending_text))
                pending_text = []
                if text:
                    yield ("assistant", text)
            text = sanitize(tool_one_liner(block))
            if text:
                yield ("tool", text)
        # thinking / anything else: dropped
    if pending_text:
        text = sanitize("\n".join(pending_text))
        if text:
            yield ("assistant", text)


def file_fingerprint(fh, length):
    fh.seek(0)
    return hashlib.sha1(fh.read(min(FP_BYTES, length))).hexdigest()


def iter_complete_lines(fh, start, end):
    """Yield raw lines from [start, end) that end in \\n; return consumed offset."""
    fh.seek(start)
    consumed = start
    buf = fh.read(end - start)
    last_nl = buf.rfind(b"\n")
    if last_nl < 0:
        return consumed, []
    consumed = start + last_nl + 1
    return consumed, buf[: last_nl + 1].split(b"\n")


def process_lines(lines, state):
    """Parse raw JSONL lines into message tuples appended onto state."""
    for raw in lines:
        if not raw or not any(marker in raw for marker in PREFILTER):
            continue
        try:
            record = json.loads(raw.decode("utf-8", "ignore"))
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(record, dict):
            continue
        if record.get("isSidechain") or record.get("isMeta"):
            continue
        rtype = record.get("type")
        if rtype == "user":
            gen = extract_user(record)
        elif rtype == "assistant":
            gen = extract_assistant(record)
        else:
            continue
        ts = parse_ts(record.get("timestamp"), state["last_ts"])
        for role, text in gen:
            state["messages"].append((role, ts, text))
            state["last_ts"] = max(state["last_ts"], ts)
            if state["first_ts"] == 0 or (ts and ts < state["first_ts"]):
                state["first_ts"] = ts
            if role == "user" and not state["title"] and not text.startswith("[Request interrupted"):
                state["title"] = " ".join(text.split())[:MAX_TITLE_CHARS]
        if not state["project"]:
            cwd = record.get("cwd")
            if isinstance(cwd, str):
                state["project"] = cwd


def refresh_fts(db, session_rowid):
    db.execute("DELETE FROM session_fts WHERE rowid = ?", (session_rowid,))
    row = db.execute(
        "SELECT group_concat(text, char(10)) FROM ("
        "  SELECT text FROM session_messages"
        "  WHERE session_id = ? AND role != 'tool' ORDER BY seq)",
        (session_rowid,),
    ).fetchone()
    body = row[0] or ""
    if len(body.encode("utf-8", "ignore")) > MAX_BODY_BYTES:
        body = body.encode("utf-8", "ignore")[:MAX_BODY_BYTES].decode("utf-8", "ignore")
    if body:
        db.execute(
            "INSERT INTO session_fts(rowid, body) VALUES (?, ?)", (session_rowid, body)
        )


def delete_session(db, path):
    row = db.execute("SELECT id FROM sessions WHERE file = ?", (path,)).fetchone()
    if row:
        db.execute("DELETE FROM session_messages WHERE session_id = ?", (row[0],))
        db.execute("DELETE FROM session_fts WHERE rowid = ?", (row[0],))
        db.execute("DELETE FROM sessions WHERE id = ?", (row[0],))
    db.execute("DELETE FROM session_files WHERE path = ?", (path,))


def ingest_file(db, path, force):
    try:
        st = os.stat(path)
    except OSError:
        return
    size = st.st_size
    cursor = db.execute(
        "SELECT offset, mtime, dev, ino, fp FROM session_files WHERE path = ?", (path,)
    ).fetchone()

    start = 0
    if cursor and not force:
        offset, mtime, dev, ino, fp = cursor
        same_identity = dev == st.st_dev and ino == st.st_ino
        if same_identity and size == offset and mtime == int(st.st_mtime_ns):
            return
        with open(path, "rb") as fh:
            current_fp = file_fingerprint(fh, min(offset, size)) if offset else ""
        if same_identity and size >= offset and (not offset or current_fp == fp):
            start = offset
        else:
            delete_session(db, path)
            cursor = None
    elif cursor and force:
        delete_session(db, path)
        cursor = None

    with open(path, "rb") as fh:
        consumed, lines = iter_complete_lines(fh, start, size)
        if consumed <= start and cursor:
            return  # nothing complete beyond the cursor yet
        new_fp = file_fingerprint(fh, min(consumed, FP_BYTES))

    sid = os.path.splitext(os.path.basename(path))[0]
    state = {"messages": [], "title": "", "project": "", "first_ts": 0, "last_ts": 0}
    process_lines(lines, state)

    db.execute("BEGIN")
    try:
        row = db.execute("SELECT id, first_ts, title, project FROM sessions WHERE sid = ?", (sid,)).fetchone()
        if row:
            rowid = row[0]
        elif state["messages"]:
            cur = db.execute(
                "INSERT INTO sessions(sid, project, file, first_ts, last_ts, msg_count, title)"
                " VALUES (?, ?, ?, 0, 0, 0, '')",
                (sid, state["project"], path),
            )
            rowid = cur.lastrowid
            row = (rowid, 0, "", state["project"])
        else:
            # No dialogue at all (noise-only or empty file): record the cursor
            # so the file is skipped next sweep, but create no session row.
            row = None
            rowid = None

        if state["messages"]:
            base_seq = db.execute(
                "SELECT COALESCE(MAX(seq), 0) FROM session_messages WHERE session_id = ?",
                (rowid,),
            ).fetchone()[0]
            db.executemany(
                "INSERT OR IGNORE INTO session_messages(session_id, seq, role, ts, text)"
                " VALUES (?, ?, ?, ?, ?)",
                [
                    (rowid, base_seq + i + 1, role, ts, text)
                    for i, (role, ts, text) in enumerate(state["messages"])
                ],
            )
            refresh_fts(db, rowid)

        if row is not None:
            first_ts = row[1] or state["first_ts"]
            title = row[2] or state["title"]
            project = row[3] or state["project"]
            db.execute(
                "UPDATE sessions SET project = ?, file = ?, first_ts = ?,"
                " last_ts = MAX(last_ts, ?), title = ?,"
                " msg_count = (SELECT count(*) FROM session_messages WHERE session_id = ?)"
                " WHERE id = ?",
                (project, path, first_ts, state["last_ts"], title, rowid, rowid),
            )
        db.execute(
            "INSERT INTO session_files(path, offset, mtime, dev, ino, fp)"
            " VALUES (?, ?, ?, ?, ?, ?)"
            " ON CONFLICT(path) DO UPDATE SET offset=excluded.offset,"
            " mtime=excluded.mtime, dev=excluded.dev, ino=excluded.ino, fp=excluded.fp",
            (path, consumed, int(st.st_mtime_ns), st.st_dev, st.st_ino, new_fp),
        )
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def main():
    force = "--force" in sys.argv[1:]
    db_path = os.environ.get("CP_DB")
    if not db_path:
        print("ingest_sessions: CP_DB not set", file=sys.stderr)
        return 2
    projects_dir = os.environ.get(
        "CP_PROJECTS_DIR", os.path.join(os.path.expanduser("~"), ".claude", "projects")
    )
    run_dir = os.environ.get("CP_RUN_DIR", "/tmp")

    os.makedirs(run_dir, exist_ok=True)
    lock_path = os.path.join(run_dir, "session_ingest.lock")
    status_path = os.path.join(run_dir, "session_ingest_status")
    lock_fh = open(lock_path, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another ingest is running

    try:
        with open(status_path, "w") as fh:
            fh.write("running")

        db = sqlite3.connect(db_path, timeout=5)
        db.isolation_level = None
        db.execute("PRAGMA busy_timeout = 5000")
        db.execute("PRAGMA journal_mode = WAL")
        db.execute("PRAGMA synchronous = NORMAL")

        seen = set()
        complete = True
        if os.path.isdir(projects_dir):
            for entry in sorted(os.listdir(projects_dir)):
                subdir = os.path.join(projects_dir, entry)
                if not os.path.isdir(subdir):
                    continue
                for name in sorted(os.listdir(subdir)):
                    if not name.endswith(".jsonl"):
                        continue
                    path = os.path.join(subdir, name)
                    if not os.path.isfile(path):
                        continue
                    seen.add(path)
                    try:
                        ingest_file(db, path, force)
                    except sqlite3.Error as exc:
                        complete = False
                        print("ingest_sessions: {}: {}".format(path, exc), file=sys.stderr)

        # Reconcile deletions only after a fully successful enumeration.
        if complete:
            stale = [
                r[0]
                for r in db.execute("SELECT path FROM session_files").fetchall()
                if r[0] not in seen
            ]
            for path in stale:
                db.execute("BEGIN")
                try:
                    delete_session(db, path)
                    db.execute("COMMIT")
                except Exception:
                    db.execute("ROLLBACK")
                    raise
        db.close()

        with open(status_path, "w") as fh:
            fh.write("done")
        return 0
    finally:
        lock_fh.close()


if __name__ == "__main__":
    sys.exit(main())
