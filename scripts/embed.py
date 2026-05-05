#!/usr/bin/env python3
"""embed.py — embeddings, KNN, and a long-running daemon for claude-prompts.

Subcommands:
  daemon                Run as a unix-socket daemon (idle-times out).
  daemon-ensure         Ping; if no daemon, spawn one (detached).
  daemon-stop           Tell the running daemon to shut down.

  call-knn-id <id>      RPC: KNN to <id>. Falls back to direct mode on failure.
  call-knn-text <text>  RPC: KNN to free-form text.
  call-hybrid <text>    RPC: hybrid FTS5+vec via RRF.
  call-backfill-async   RPC: kick async backfill on the daemon.
  call-ping             RPC: liveness.
  call-backfill-status  RPC: report backfill thread state and counts.

  backfill              Direct (synchronous) backfill — fallback when no daemon.
  search-id <id>        Direct KNN by id — fallback when no daemon.

Reads $CP_DB, $CP_SCOPE_FILE, $CP_RUN_DIR from the environment.

Embedding model: BAAI/bge-small-en-v1.5 (384-dim).
Vector store:    prompts_vec virtual table (sqlite-vec extension).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from typing import Iterable

# sqlite_vec, fastembed, and sqlite3 are import-heavy. Defer them until a
# code path that actually needs them runs — the call-* RPC clients hit none
# of these and want sub-50ms cold-start.
def _lazy_text_embedding():
    from fastembed import TextEmbedding
    return TextEmbedding


MODEL_NAME = "BAAI/bge-small-en-v1.5"
EMBED_DIM = 384
BATCH_SIZE = 64
RRF_K = 60
IDLE_TIMEOUT = 600
ACCEPT_TIMEOUT = 30


# ---------------- Row rendering (mirrors cp_render_rows in render.sh) ----------------
# These glyphs and 256-color codes MUST stay in sync with scripts/glyphs.sh.

_GLYPHS_NERD = {
    "pin_on": "★",   # ★
    "pin_off": " ",
    "hot": "•",      # •
    "warm": "·",     # ·
    "cold": " ",
    "trunc": "…",    # …
}
_GLYPHS_ASCII = {
    "pin_on": "*",
    "pin_off": " ",
    "hot": ".",
    "warm": ",",
    "cold": " ",
    "trunc": "...",
}
_PIN_ON_COLOR = 214   # amber
_HOT_COLOR = 244
_WARM_COLOR = 244
_PROJ_COLOR = 243
_LABEL_COLOR = 179
_RESET = "\x1b[0m"

_ONE_DAY_MS = 86400000
_SEVEN_DAYS_MS = 604800000


def _render_rows_py(rows, scope, now_ms, use_ascii=False):
    g = _GLYPHS_ASCII if use_ascii else _GLYPHS_NERD
    ansi_pin_on = "\x1b[38;5;{}m{}{}".format(_PIN_ON_COLOR, g["pin_on"], _RESET)
    ansi_hot = "\x1b[38;5;{}m{}{}".format(_HOT_COLOR, g["hot"], _RESET)
    ansi_warm = "\x1b[38;5;{}m{}{}".format(_WARM_COLOR, g["warm"], _RESET)
    ansi_proj_open = "\x1b[38;5;{}m".format(_PROJ_COLOR)
    pin_off = g["pin_off"]
    cold = g["cold"]
    trunc = g["trunc"]
    empty_chip = " " * 16

    show_chip = scope == "everywhere" or not scope

    out = []
    for row in rows:
        rid, display, project, ts, pinned, label = row
        if rid is None or rid == "":
            continue

        pin_str = ansi_pin_on if pinned == 1 else pin_off

        age_ms = now_ms - int(ts)
        if age_ms < _ONE_DAY_MS:
            rec_str = ansi_hot
        elif age_ms < _SEVEN_DAYS_MS:
            rec_str = ansi_warm
        else:
            rec_str = cold

        if show_chip:
            if project:
                chip_name = project.rsplit("/", 1)[-1]
                if len(chip_name) > 14:
                    chip_name = chip_name[:14]
                else:
                    chip_name = (chip_name + " " * 14)[:14]
                chip_str = "{}{}{}  ".format(ansi_proj_open, chip_name, _RESET)
            else:
                chip_str = empty_chip
        else:
            chip_str = ""

        label_str = ""
        if label:
            lbl = label.replace("\x1b", "")
            if len(lbl) > 60:
                lbl = lbl[:60]
            label_str = "\x1b[38;5;{}m[{}]{} ".format(_LABEL_COLOR, lbl, _RESET)

        disp = display or ""
        if len(disp) > 500:
            disp = disp[:500] + trunc

        out.append("{}\x1f{} {} {}{}{}\n".format(rid, pin_str, rec_str, chip_str, label_str, disp))
    return out


# ---------------- Path / env helpers ----------------

def db_path() -> str:
    p = os.environ.get("CP_DB")
    if not p:
        sys.stderr.write("embed.py: CP_DB not set\n")
        sys.exit(2)
    return p


def run_dir() -> str:
    p = os.environ.get("CP_RUN_DIR")
    if not p:
        sys.stderr.write("embed.py: CP_RUN_DIR not set\n")
        sys.exit(2)
    return p


def sock_path() -> str:
    return os.path.join(run_dir(), "embed.sock")


def scope_default() -> str:
    f = os.environ.get("CP_SCOPE_FILE", "")
    if f and os.path.isfile(f):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                s = fh.read().strip()
            return s if s else "everywhere"
        except OSError:
            pass
    return "everywhere"


def case_default() -> str:
    f = os.environ.get("CP_CASE_FILE", "")
    if f and os.path.isfile(f):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                s = fh.read().strip()
            return s if s else "insensitive"
        except OSError:
            pass
    return "insensitive"


# ---------------- DB helpers ----------------

def open_db():
    import sqlite3
    import sqlite_vec
    db = sqlite3.connect(db_path(), timeout=3.0)
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    db.execute(
        f"CREATE VIRTUAL TABLE IF NOT EXISTS prompts_vec USING vec0("
        f"embedding float[{EMBED_DIM}])"
    )
    return db


def to_blob(vec) -> bytes:
    return struct.pack(f"{EMBED_DIM}f", *vec.tolist())


def compose_text(db, prompt_id: int) -> str:
    row = db.execute(
        "SELECT display_full FROM prompts WHERE id = ?", (prompt_id,)
    ).fetchone()
    if not row:
        return ""
    body = row[0] or ""
    pastes = db.execute(
        "SELECT content FROM paste_contents WHERE prompt_id = ? ORDER BY paste_id",
        (prompt_id,),
    ).fetchall()
    if pastes:
        body = body + "\n" + "\n".join(p[0] for p in pastes if p[0])
    return body


def pending_rows(db) -> list[tuple[int, str]]:
    """Rows in prompts but not in prompts_vec, ordered newest-first so just-
    ingested prompts become available for similarity ranking before older ones."""
    rows = db.execute(
        """
        SELECT p.id, p.display_full
        FROM prompts p
        LEFT JOIN prompts_vec v ON v.rowid = p.id
        WHERE v.rowid IS NULL
        ORDER BY p.ts DESC, p.id DESC
        """
    ).fetchall()
    out: list[tuple[int, str]] = []
    for pid, df in rows:
        body = df or ""
        pastes = db.execute(
            "SELECT content FROM paste_contents WHERE prompt_id = ? ORDER BY paste_id",
            (pid,),
        ).fetchall()
        if pastes:
            body = body + "\n" + "\n".join(p[0] for p in pastes if p[0])
        if body.strip():
            out.append((pid, body))
    return out


def fts_query_from(text: str) -> str:
    parts = []
    for token in text.split():
        clean = "".join(c for c in token if c.isalnum() or c in "_-")
        if clean:
            parts.append(clean + "*")
    return " AND ".join(parts)


# ---------------- Direct (no daemon) paths ----------------

def backfill_sync() -> int:
    db = open_db()
    pending = pending_rows(db)
    if not pending:
        db.close()
        return 0

    sys.stderr.write(f"embed.py: backfilling {len(pending)} prompts…\n")
    sys.stderr.flush()

    Model = _lazy_text_embedding()
    model = Model(model_name=MODEL_NAME)

    done = 0
    for start in range(0, len(pending), BATCH_SIZE):
        batch = pending[start : start + BATCH_SIZE]
        ids = [pid for pid, _ in batch]
        texts = [t for _, t in batch]
        vecs = list(model.embed(texts))
        with db:
            db.executemany(
                "INSERT INTO prompts_vec(rowid, embedding) VALUES (?, ?)",
                [(pid, to_blob(v)) for pid, v in zip(ids, vecs)],
            )
        done += len(batch)
        sys.stderr.write(f"\rembed.py: {done}/{len(pending)}")
        sys.stderr.flush()
    sys.stderr.write("\nembed.py: done\n")
    db.close()
    return len(pending)


def search_id_direct(source_id: int, limit: int) -> list[int]:
    db = open_db()
    try:
        row = db.execute(
            "SELECT embedding FROM prompts_vec WHERE rowid = ?", (source_id,)
        ).fetchone()
        if row:
            blob = row[0]
        else:
            body = compose_text(db, source_id)
            if not body.strip():
                return []
            Model = _lazy_text_embedding()
            model = Model(model_name=MODEL_NAME)
            vec = next(iter(model.embed([body])))
            blob = to_blob(vec)
            with db:
                db.execute(
                    "INSERT INTO prompts_vec(rowid, embedding) VALUES (?, ?)",
                    (source_id, blob),
                )
        return _knn_blob(db, blob, limit, scope_default(), exclude_id=source_id)
    finally:
        db.close()


def _knn_blob(db, blob: bytes, limit: int, scope: str, exclude_id: int | None = None) -> list[int]:
    proj_filter = "" if scope == "everywhere" else scope
    k_window = max(limit * 4, 200)
    excl_active = 1 if exclude_id is not None else 0
    excl_id = exclude_id if exclude_id is not None else 0
    rows = db.execute(
        """
        WITH knn AS (
          SELECT rowid AS id, distance
          FROM prompts_vec
          WHERE embedding MATCH ?
          ORDER BY distance
          LIMIT ?
        )
        SELECT k.id
        FROM knn k JOIN prompts p ON p.id = k.id
        WHERE (? = 0 OR k.id != ?)
          AND (? = '' OR p.project = ?)
        ORDER BY k.distance
        LIMIT ?
        """,
        (blob, k_window, excl_active, excl_id, proj_filter, proj_filter, limit),
    ).fetchall()
    return [r[0] for r in rows]


# ---------------- Daemon ----------------

class Daemon:
    def __init__(self):
        self.sock = sock_path()
        self.last_request = time.time()
        self.bg_thread: threading.Thread | None = None
        self.bg_total = 0
        self.bg_done = 0
        self.bg_lock = threading.Lock()
        self.shutdown = False

        Model = _lazy_text_embedding()
        self.model = Model(model_name=MODEL_NAME)
        # Warm-up pass: first call has higher latency; do one tiny embed up front.
        list(self.model.embed(["warmup"]))

    def serve(self) -> None:
        try:
            os.unlink(self.sock)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock)
        os.chmod(self.sock, 0o600)
        srv.listen(8)
        srv.settimeout(ACCEPT_TIMEOUT)
        try:
            while not self.shutdown:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    if time.time() - self.last_request > IDLE_TIMEOUT:
                        return
                    continue
                self._handle(conn)
        finally:
            try:
                os.unlink(self.sock)
            except FileNotFoundError:
                pass
            srv.close()

    def _handle(self, conn):
        with conn:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    return
                data += chunk
            try:
                req = json.loads(data.decode("utf-8"))
                resp = self._dispatch(req)
            except Exception as e:  # noqa: BLE001
                resp = {"ok": False, "err": f"{type(e).__name__}: {e}"}
            try:
                conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            except OSError:
                pass
            self.last_request = time.time()

    def _dispatch(self, req: dict) -> dict:
        cmd = req.get("cmd")
        if cmd == "ping":
            return {"ok": True}
        if cmd == "shutdown":
            self.shutdown = True
            return {"ok": True}
        if cmd == "knn-id":
            return {"ok": True, "ids": self._knn_id(int(req["id"]), int(req.get("limit", 200)), req.get("scope", "everywhere"))}
        if cmd == "knn-text":
            return {"ok": True, "ids": self._knn_text(req["text"], int(req.get("limit", 200)), req.get("scope", "everywhere"))}
        if cmd == "hybrid":
            return {"ok": True, "ids": self._hybrid(req["text"], int(req.get("limit", 200)), req.get("scope", "everywhere"))}
        if cmd == "hybrid-rendered":
            return {"ok": True, "rows": self._hybrid_rendered(
                req["text"],
                int(req.get("limit", 200)),
                req.get("scope", "everywhere"),
                bool(req.get("no_nerd", False)),
            )}
        if cmd == "backfill-async":
            self._kick_backfill()
            return {"ok": True}
        if cmd == "backfill-status":
            running = self.bg_thread is not None and self.bg_thread.is_alive()
            with self.bg_lock:
                return {"ok": True, "running": running, "done": self.bg_done, "total": self.bg_total}
        return {"ok": False, "err": f"unknown cmd: {cmd}"}

    # ---- search ops ----

    def _knn_id(self, source_id: int, limit: int, scope: str) -> list[int]:
        db = open_db()
        try:
            row = db.execute(
                "SELECT embedding FROM prompts_vec WHERE rowid = ?", (source_id,)
            ).fetchone()
            if row:
                blob = row[0]
            else:
                body = compose_text(db, source_id)
                if not body.strip():
                    return []
                vec = next(iter(self.model.embed([body])))
                blob = to_blob(vec)
                with db:
                    db.execute(
                        "INSERT INTO prompts_vec(rowid, embedding) VALUES (?, ?)",
                        (source_id, blob),
                    )
            return _knn_blob(db, blob, limit, scope, exclude_id=source_id)
        finally:
            db.close()

    def _knn_text(self, text: str, limit: int, scope: str) -> list[int]:
        if not text.strip():
            return []
        db = open_db()
        try:
            vec = next(iter(self.model.embed([text])))
            blob = to_blob(vec)
            return _knn_blob(db, blob, limit, scope)
        finally:
            db.close()

    def _hybrid(self, text: str, limit: int, scope: str) -> list[int]:
        if not text.strip():
            return []
        fts_q = fts_query_from(text)
        # Always embed for vec side. Even if FTS query is empty (symbols-only),
        # we can still rank by vec.
        vec = next(iter(self.model.embed([text])))
        blob = to_blob(vec)

        proj_filter = "" if scope == "everywhere" else scope
        k_window = max(limit * 4, 200)

        db = open_db()
        try:
            if fts_q:
                rows = db.execute(
                    """
                    WITH
                    fts AS (
                      SELECT rowid AS id, ROW_NUMBER() OVER (ORDER BY rank) AS rk
                      FROM prompts_fts WHERE prompts_fts MATCH ?
                      LIMIT ?
                    ),
                    vec AS (
                      SELECT rowid AS id, ROW_NUMBER() OVER (ORDER BY distance) AS rk
                      FROM prompts_vec WHERE embedding MATCH ? AND k = ?
                    ),
                    fused AS (
                      SELECT id, SUM(1.0 / (? + rk)) AS score
                      FROM (
                        SELECT id, rk FROM fts
                        UNION ALL
                        SELECT id, rk FROM vec
                      )
                      GROUP BY id
                    )
                    SELECT p.id
                    FROM fused f JOIN prompts p ON p.id = f.id
                    WHERE (? = '' OR p.project = ?)
                    ORDER BY p.pinned DESC, f.score DESC, p.ts DESC
                    LIMIT ?
                    """,
                    (fts_q, k_window, blob, k_window, RRF_K, proj_filter, proj_filter, limit),
                ).fetchall()
            else:
                # Vec-only path: still pinned-on-top.
                rows = db.execute(
                    """
                    WITH knn AS (
                      SELECT rowid AS id, distance
                      FROM prompts_vec
                      WHERE embedding MATCH ?
                      ORDER BY distance
                      LIMIT ?
                    )
                    SELECT k.id
                    FROM knn k JOIN prompts p ON p.id = k.id
                    WHERE (? = '' OR p.project = ?)
                    ORDER BY p.pinned DESC, k.distance
                    LIMIT ?
                    """,
                    (blob, k_window, proj_filter, proj_filter, limit),
                ).fetchall()
            return [r[0] for r in rows]
        finally:
            db.close()

    def _hybrid_rendered(self, text: str, limit: int, scope: str, use_ascii: bool) -> list[str]:
        ids = self._hybrid(text, limit, scope)
        if not ids:
            return []
        db = open_db()
        try:
            values_sql = ",".join("({}, {})".format(int(pid), rk) for rk, pid in enumerate(ids))
            rows = db.execute(
                "WITH ranked(id, rk) AS (VALUES " + values_sql + ") "
                "SELECT p.id, "
                "  COALESCE(NULLIF(p.display_preview, ''), p.display) AS display, "
                "  p.project, p.ts, p.pinned, COALESCE(p.label, '') "
                "FROM ranked r JOIN prompts p ON p.id = r.id "
                "ORDER BY r.rk"
            ).fetchall()
        finally:
            db.close()
        now_ms = int(time.time() * 1000)
        return _render_rows_py(rows, scope, now_ms, use_ascii=use_ascii)

    # ---- backfill thread ----

    def _kick_backfill(self) -> None:
        if self.bg_thread is not None and self.bg_thread.is_alive():
            return
        self.bg_thread = threading.Thread(target=self._do_backfill, daemon=True)
        self.bg_thread.start()

    def _do_backfill(self) -> None:
        try:
            db = open_db()
            pending = pending_rows(db)
            with self.bg_lock:
                self.bg_total = len(pending)
                self.bg_done = 0
            for start in range(0, len(pending), BATCH_SIZE):
                batch = pending[start : start + BATCH_SIZE]
                ids = [pid for pid, _ in batch]
                texts = [t for _, t in batch]
                vecs = list(self.model.embed(texts))
                with db:
                    db.executemany(
                        "INSERT INTO prompts_vec(rowid, embedding) VALUES (?, ?)",
                        [(pid, to_blob(v)) for pid, v in zip(ids, vecs)],
                    )
                with self.bg_lock:
                    self.bg_done += len(batch)
            db.close()
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"embed.py: backfill thread error: {e}\n")


# ---------------- Daemon client utilities ----------------

def daemon_call(req: dict, timeout: float = 10.0) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path())
    try:
        s.sendall((json.dumps(req) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    finally:
        s.close()
    return json.loads(data.decode("utf-8"))


def daemon_ping(timeout: float = 0.5) -> bool:
    try:
        resp = daemon_call({"cmd": "ping"}, timeout=timeout)
        return bool(resp.get("ok"))
    except Exception:
        return False


def daemon_ensure(wait_seconds: float = 8.0) -> bool:
    if daemon_ping(0.3):
        return True
    log_path = os.path.join(run_dir(), "embed_daemon.log")
    script = os.path.realpath(__file__)
    log = open(log_path, "ab")
    try:
        subprocess.Popen(
            [sys.executable, script, "daemon"],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        log.close()
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if daemon_ping(0.3):
            return True
        time.sleep(0.1)
    return False


# ---------------- main ----------------

def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("backfill")

    s = sub.add_parser("search-id")
    s.add_argument("id", type=int)
    s.add_argument("--limit", type=int, default=200)

    sub.add_parser("daemon")
    sub.add_parser("daemon-ensure")
    sub.add_parser("daemon-stop")

    s = sub.add_parser("call-knn-id")
    s.add_argument("id", type=int)
    s.add_argument("--limit", type=int, default=200)

    s = sub.add_parser("call-knn-text")
    s.add_argument("text")
    s.add_argument("--limit", type=int, default=200)

    s = sub.add_parser("call-hybrid")
    s.add_argument("text")
    s.add_argument("--limit", type=int, default=200)

    s = sub.add_parser("call-hybrid-rendered")
    s.add_argument("text")
    s.add_argument("--limit", type=int, default=200)
    s.add_argument("--scope", default=None)
    s.add_argument("--no-nerd", action="store_true", default=False)

    sub.add_parser("call-backfill-async")
    sub.add_parser("call-ping")
    sub.add_parser("call-backfill-status")

    args = ap.parse_args()

    if args.cmd == "backfill":
        backfill_sync()
        return 0
    if args.cmd == "search-id":
        for pid in search_id_direct(args.id, args.limit):
            print(pid)
        return 0
    if args.cmd == "daemon":
        Daemon().serve()
        return 0
    if args.cmd == "daemon-ensure":
        ok = daemon_ensure()
        return 0 if ok else 1
    if args.cmd == "daemon-stop":
        try:
            daemon_call({"cmd": "shutdown"}, timeout=1.0)
        except Exception:
            pass
        return 0
    if args.cmd == "call-ping":
        sys.exit(0 if daemon_ping() else 1)
    if args.cmd.startswith("call-"):
        verb = args.cmd[5:]
        scope_override = getattr(args, "scope", None)
        req: dict = {"cmd": verb, "scope": scope_override if scope_override else scope_default()}
        if hasattr(args, "id"):
            req["id"] = args.id
        if hasattr(args, "text"):
            req["text"] = args.text
        if hasattr(args, "limit"):
            req["limit"] = args.limit
        if getattr(args, "no_nerd", False):
            req["no_nerd"] = True
        try:
            resp = daemon_call(req, timeout=10.0)
        except (socket.error, FileNotFoundError, ConnectionRefusedError) as e:
            sys.stderr.write(f"embed.py: daemon unreachable ({e})\n")
            return 2
        if not resp.get("ok"):
            sys.stderr.write(f"embed.py: {resp.get('err','')}\n")
            return 1
        if verb == "backfill-status":
            json.dump({k: resp.get(k) for k in ("running", "done", "total")}, sys.stdout)
            sys.stdout.write("\n")
        elif verb == "hybrid-rendered":
            buf = sys.stdout.buffer
            for row in resp.get("rows", []):
                buf.write(row.encode("utf-8"))
            buf.flush()
        else:
            for pid in resp.get("ids", []):
                print(pid)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
