"""SQLite: projects, pairing_codes, alerts_log. Mỗi thao tác mở connection riêng."""
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

_WRITE_LOCK = threading.Lock()  # serialize ghi để tránh database locked

SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_name TEXT NOT NULL,
    api_key_hash TEXT UNIQUE,              -- sha256(api_key), không lưu plaintext
    status TEXT NOT NULL DEFAULT 'pending', -- pending | linked | disabled
    telegram_chat_id TEXT,
    created_at TEXT NOT NULL,
    linked_at TEXT
);

CREATE TABLE IF NOT EXISTS pairing_codes (
    code TEXT PRIMARY KEY,                 -- SEC-1234
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    api_key_plain TEXT,                    -- tiết lộ 1 lần cho client, dọn sau
    revealed_at TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);

CREATE TABLE IF NOT EXISTS alerts_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL,
    rule_id TEXT,
    severity TEXT,
    host TEXT,
    message TEXT,
    delivered INTEGER NOT NULL DEFAULT 0,
    received_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pairing_project ON pairing_codes(project_id);
CREATE INDEX IF NOT EXISTS idx_alerts_project ON alerts_log(project_id);
"""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: Optional[datetime] = None) -> str:
    return (dt or utcnow()).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> Optional[datetime]:
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def init_db(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with _connect(path) as conn:
        conn.executescript(SCHEMA)


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


@contextmanager
def connect(db_path: str):
    conn = _connect(db_path)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------- projects

def create_project(db_path: str, name: str) -> int:
    with _WRITE_LOCK, connect(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO projects (project_name, status, created_at) VALUES (?, 'pending', ?)",
            (name, iso()),
        )
        return int(cur.lastrowid)


def get_project(db_path: str, project_id: int) -> Optional[sqlite3.Row]:
    with connect(db_path) as conn:
        return conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()


def project_by_api_key_hash(db_path: str, key_hash: str) -> Optional[sqlite3.Row]:
    with connect(db_path) as conn:
        return conn.execute(
            "SELECT * FROM projects WHERE api_key_hash = ? AND status = 'linked'",
            (key_hash,),
        ).fetchone()


# ------------------------------------------------------------ pairing codes

def issue_pairing_code(db_path: str, project_id: int, ttl_sec: int, gen_code) -> str:
    """gen_code: callable trả mã chưa dùng (thử lại khi trùng)."""
    with _WRITE_LOCK, connect(db_path) as conn:
        for _ in range(200):
            code = gen_code()
            row = conn.execute(
                "SELECT 1 FROM pairing_codes WHERE code = ?", (code,)
            ).fetchone()
            if row is None:
                conn.execute(
                    "INSERT INTO pairing_codes (code, project_id, created_at, expires_at)"
                    " VALUES (?, ?, ?, ?)",
                    (code, project_id, iso(), iso(utcnow() + timedelta(seconds=ttl_sec))),
                )
                return code
    raise RuntimeError("không tạo được mã pairing duy nhất")


class PairingError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def complete_pairing(db_path: str, code: str, chat_id: str, gen_api_key, key_hash) -> dict:
    """Ghép nối: mã hợp lệ + chưa dùng + chưa hết hạn -> lưu chat_id, sinh api_key.

    Trả dict {project_id, project_name, api_key} hoặc raise PairingError.
    gen_api_key: callable -> plaintext key; key_hash: callable(plain) -> hash.
    """
    now = iso()
    with _WRITE_LOCK, connect(db_path) as conn:
        row = conn.execute(
            "SELECT p.*, pc.code AS _code, pc.expires_at AS _expires, pc.used_at AS _used"
            " FROM pairing_codes pc JOIN projects p ON p.id = pc.project_id"
            " WHERE pc.code = ?",
            (code.upper(),),
        ).fetchone()
        if row is None:
            raise PairingError("Mã không tồn tại. Hãy chạy lại lệnh pair trên server dự án.")
        if row["_used"]:
            raise PairingError("Mã đã được sử dụng. Hãy tạo mã mới trên server dự án.")
        exp = parse_iso(row["_expires"])
        if exp is None or exp < utcnow():
            raise PairingError("Mã đã hết hạn (sống 10 phút). Hãy tạo mã mới.")
        api_key = gen_api_key()
        conn.execute(
            "UPDATE projects SET telegram_chat_id = ?, status = 'linked',"
            " api_key_hash = ?, linked_at = ? WHERE id = ?",
            (str(chat_id), key_hash(api_key), now, row["id"]),
        )
        conn.execute(
            "UPDATE pairing_codes SET used_at = ?, api_key_plain = ? WHERE code = ?",
            (now, api_key, code.upper()),
        )
        return {"project_id": row["id"], "project_name": row["project_name"], "api_key": api_key}


def pairing_status(db_path: str, code: str) -> Optional[dict]:
    """Trạng thái mã: pending | linked (kèm api_key nếu chưa qua cửa sổ reveal)."""
    with connect(db_path) as conn:
        row = conn.execute(
            "SELECT pc.*, p.project_name, p.status AS p_status"
            " FROM pairing_codes pc JOIN projects p ON p.id = pc.project_id"
            " WHERE pc.code = ?",
            (code.upper(),),
        ).fetchone()
        if row is None:
            return None
    out: dict[str, Any] = {"status": "pending", "project_name": row["project_name"]}
    if row["p_status"] == "linked":
        out["status"] = "linked"
        if row["api_key_plain"]:
            out["api_key"] = row["api_key_plain"]
    return out


def mark_revealed(db_path: str, code: str) -> None:
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute(
            "UPDATE pairing_codes SET revealed_at = ? WHERE code = ? AND revealed_at IS NULL",
            (iso(), code.upper()),
        )


def cleanup(db_path: str, reveal_ttl_sec: int) -> None:
    """Dọn: xoá api_key_plain đã reveal quá lâu; xoá mã hết hạn quá 24h."""
    now = utcnow()
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute("DELETE FROM pairing_codes WHERE expires_at < ?",
                     (iso(now - timedelta(hours=24)),))
        rows = conn.execute(
            "SELECT code, revealed_at FROM pairing_codes WHERE api_key_plain IS NOT NULL"
        ).fetchall()
        for r in rows:
            rev = parse_iso(r["revealed_at"] or "")
            if rev is not None and now - rev > timedelta(seconds=reveal_ttl_sec):
                conn.execute(
                    "UPDATE pairing_codes SET api_key_plain = NULL WHERE code = ?", (r["code"],)
                )


# -------------------------------------------------------------- alerts_log

def log_alerts(db_path: str, project_id: int, rows: list[dict], delivered: bool) -> None:
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.executemany(
            "INSERT INTO alerts_log (project_id, rule_id, severity, host, message, delivered, received_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    project_id,
                    str(r.get("rule_id") or "")[:64],
                    str(r.get("severity") or "")[:16],
                    str(r.get("host") or "")[:128],
                    str(r.get("message") or r.get("notes") or "")[:500],
                    1 if delivered else 0,
                    iso(),
                )
                for r in rows
            ],
        )


def count_projects(db_path: str) -> int:
    with connect(db_path) as conn:
        return conn.execute("SELECT COUNT(*) AS n FROM projects").fetchone()["n"]
