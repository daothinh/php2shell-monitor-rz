"""SQLite schema + queries.

Central store layout
--------------------
One device (monitored server) sends at most one alert per 5-minute batch. Each
alert carries the full list of raw hit lines. That is stored twice, on purpose:

  * SQLite (this module)  -> queryable: alerts + alert_hits
  * disk mirror           -> greppable/archivable: evidence/<project>/IP-LAN_<ip>_<host>_<user>/<batch>.jsonl

Tables
------
projects    one customer/site, owns an API key and one Telegram chat
devices     one monitored host inside a project
alerts      one row per batch alert (severity = highest of its hits)
alert_hits  one row per raw log line that matched a rule (file + line + raw)
"""
import json
import logging
import re
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

log = logging.getLogger("alert-server.db")

_WRITE_LOCK = threading.Lock()  # serialize writes: avoids "database is locked"

SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_name TEXT NOT NULL,
    api_key_hash TEXT UNIQUE,              -- sha256(api_key), never plaintext
    status TEXT NOT NULL DEFAULT 'pending', -- pending | linked | disabled
    telegram_chat_id TEXT,
    created_at TEXT NOT NULL,
    linked_at TEXT
);

CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    device_name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    UNIQUE(project_id, device_name)
);

CREATE TABLE IF NOT EXISTS pairing_codes (
    code TEXT PRIMARY KEY,                 -- SEC-<UUID>
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    api_key_plain TEXT,                    -- revealed once, then cleared
    revealed_at TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);

CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    batch_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    hit_count INTEGER NOT NULL DEFAULT 0,
    rules TEXT,                            -- JSON [{"rule_id":..,"hits":..}]
    window_start TEXT,
    window_end TEXT,
    evidence_file TEXT,
    evidence_truncated INTEGER NOT NULL DEFAULT 0,
    messages INTEGER NOT NULL DEFAULT 0,   -- Telegram messages sent
    delivered INTEGER NOT NULL DEFAULT 0,  -- 1 = every message accepted
    received_at TEXT NOT NULL,
    UNIQUE(device_id, batch_id)            -- agent retries must not duplicate
);

CREATE TABLE IF NOT EXISTS alert_hits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    alert_id INTEGER NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    rule_id TEXT,
    severity TEXT,
    source TEXT,
    file TEXT,
    line INTEGER,
    ip TEXT,
    method TEXT,
    uri TEXT,
    status TEXT,
    ua TEXT,
    pid TEXT,
    raw TEXT,
    ts_utc TEXT
);

CREATE INDEX IF NOT EXISTS idx_pairing_project ON pairing_codes(project_id);
CREATE INDEX IF NOT EXISTS idx_devices_project ON devices(project_id);
CREATE INDEX IF NOT EXISTS idx_alerts_project  ON alerts(project_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_device   ON alerts(device_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_severity ON alerts(severity, id DESC);
CREATE INDEX IF NOT EXISTS idx_hits_alert      ON alert_hits(alert_id);
CREATE INDEX IF NOT EXISTS idx_hits_rule       ON alert_hits(rule_id);
CREATE INDEX IF NOT EXISTS idx_hits_file       ON alert_hits(file);
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


def slug(name: str) -> str:
    """Filesystem-safe project/device name (also used for the evidence tree)."""
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", str(name or "")).strip("._-")
    return (s or "unknown")[:64]


def _connect(db_path: str) -> sqlite3.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
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


def init_db(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with _WRITE_LOCK, connect(path) as conn:
        # Legacy (pre-device) table: keep the rows, move them out of the way.
        row = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='alerts_log'"
        ).fetchone()
        if row:
            n = conn.execute("SELECT COUNT(*) AS n FROM alerts_log").fetchone()["n"]
            if n:
                conn.execute("ALTER TABLE alerts_log RENAME TO alerts_log_legacy")
                log.warning("legacy alerts_log kept as alerts_log_legacy (%d rows)", n)
            else:
                conn.execute("DROP TABLE alerts_log")
        conn.executescript(SCHEMA)


# ---------------------------------------------------------------- telegram chat id

CHAT_ID_RE = re.compile(r"^-?[1-9][0-9]{2,14}$")


def norm_chat_id(s: str) -> str:
    """Chuẩn hoá chat ID Telegram (user: dương; group/supergroup: âm).
    ValueError nếu không hợp lệ."""
    c = str(s or "").strip().replace(" ", "")
    if not CHAT_ID_RE.fullmatch(c):
        raise ValueError("chat_id phải là số Telegram (user chat dương,"
                         " group/supergroup âm, ví dụ: 8005354626 hoặc -1001234567890)")
    return c


# ---------------------------------------------------------------- projects

def create_project(db_path: str, name: str, telegram_chat_id: Optional[str] = None) -> int:
    """Project pending; telegram_chat_id khi có là CHAT ĐÍCH script yêu cầu ghép
    (luồng chat-id pairing). Trạng thái pending cho tới khi chat đó /confirm."""
    with _WRITE_LOCK, connect(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO projects (project_name, status, created_at, telegram_chat_id)"
            " VALUES (?, 'pending', ?, ?)",
            (name, iso(), telegram_chat_id),
        )
        return int(cur.lastrowid)


def pending_codes_by_chat_id(db_path: str, chat_id: str) -> list[sqlite3.Row]:
    """Các mã pairing còn hiệu lực của mọi project CHỜ /confirm theo chat ID.
    Một chat (user hoặc group) có thể có nhiều server đang chờ cùng lúc."""
    with connect(db_path) as conn:
        return conn.execute(
            """
            SELECT pc.code, p.project_name, p.id AS project_id
            FROM pairing_codes pc
            JOIN projects p ON p.id = pc.project_id
            WHERE p.telegram_chat_id = ?
              AND p.status = 'pending'
              AND pc.used_at IS NULL
              AND pc.expires_at > ?
            ORDER BY pc.expires_at
            """,
            (str(chat_id), iso()),
        ).fetchall()


def get_project(db_path: str, project_id: int) -> Optional[sqlite3.Row]:
    with connect(db_path) as conn:
        return conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()


def project_by_api_key_hash(db_path: str, key_hash: str) -> Optional[sqlite3.Row]:
    with connect(db_path) as conn:
        return conn.execute(
            "SELECT * FROM projects WHERE api_key_hash = ? AND status = 'linked'",
            (key_hash,),
        ).fetchone()


def count_projects(db_path: str) -> int:
    with connect(db_path) as conn:
        return conn.execute("SELECT COUNT(*) AS n FROM projects").fetchone()["n"]


def projects_by_chat(db_path: str, chat_id: str) -> list[sqlite3.Row]:
    """Mọi project đã ghép với MỘT chat Telegram — một người, nhiều server/dự án."""
    with connect(db_path) as conn:
        return conn.execute(
            """
            SELECT p.id, p.project_name, p.status, p.linked_at,
                   (SELECT COUNT(*) FROM devices d WHERE d.project_id = p.id) AS device_count,
                   (SELECT MAX(a.received_at) FROM alerts a WHERE a.project_id = p.id)
                       AS last_alert_at
            FROM projects p
            WHERE p.telegram_chat_id = ? AND p.status != 'pending'
            ORDER BY p.linked_at
            """,
            (str(chat_id),),
        ).fetchall()


# ---------------------------------------------------------------- devices

def upsert_device(db_path: str, project_id: int, device_name: str) -> int:
    """Register/refresh a device and return its id."""
    name = slug(device_name)
    now = iso()
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute(
            "INSERT INTO devices (project_id, device_name, created_at, last_seen_at)"
            " VALUES (?, ?, ?, ?)"
            " ON CONFLICT(project_id, device_name)"
            " DO UPDATE SET last_seen_at = excluded.last_seen_at",
            (project_id, name, now, now),
        )
        row = conn.execute(
            "SELECT id FROM devices WHERE project_id = ? AND device_name = ?",
            (project_id, name),
        ).fetchone()
        return int(row["id"])


def list_devices(db_path: str, project_id: Optional[int] = None) -> list[sqlite3.Row]:
    with connect(db_path) as conn:
        if project_id is None:
            return conn.execute(
                "SELECT d.*, p.project_name FROM devices d"
                " JOIN projects p ON p.id = d.project_id"
                " ORDER BY p.project_name, d.device_name"
            ).fetchall()
        return conn.execute(
            "SELECT * FROM devices WHERE project_id = ? ORDER BY device_name", (project_id,)
        ).fetchall()


# ------------------------------------------------------------ pairing codes

def issue_pairing_code(db_path: str, project_id: int, ttl_sec: int, gen_code) -> str:
    """gen_code: callable returning an unused code (retried on collision)."""
    with _WRITE_LOCK, connect(db_path) as conn:
        for _ in range(200):
            code = gen_code()
            if conn.execute("SELECT 1 FROM pairing_codes WHERE code = ?", (code,)).fetchone():
                continue
            conn.execute(
                "INSERT INTO pairing_codes (code, project_id, created_at, expires_at)"
                " VALUES (?, ?, ?, ?)",
                (code, project_id, iso(), iso(utcnow() + timedelta(seconds=ttl_sec))),
            )
            return code
    raise RuntimeError("cannot allocate a unique pairing code")


class PairingError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def complete_pairing(db_path: str, code: str, chat_id: str, gen_api_key, key_hash) -> dict:
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


# ---------------------------------------------------------------- alerts

_HIT_FIELDS = ("rule_id", "severity", "source", "file", "line", "ip", "method",
               "uri", "status", "ua", "pid", "raw", "ts_utc")


def store_alert(
    db_path: str,
    project_id: int,
    device_id: int,
    alert: dict,
    evidence_file: str,
    delivered: bool,
    messages: int,
) -> Optional[int]:
    """Insert one batch alert + its hits. Returns None when it was a duplicate."""
    hits = alert.get("evidence") or []
    batch = str(alert.get("batch_id") or "")
    if not batch:
        return None
    with _WRITE_LOCK, connect(db_path) as conn:
        cur = conn.execute(
            "INSERT OR IGNORE INTO alerts (project_id, device_id, batch_id, severity,"
            " hit_count, rules, window_start, window_end, evidence_file,"
            " evidence_truncated, messages, delivered, received_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                project_id,
                device_id,
                batch,
                str(alert.get("severity") or "INFO").upper(),
                int(alert.get("hits") or len(hits)),
                json.dumps(alert.get("rules") or [], ensure_ascii=False),
                alert.get("window_start"),
                alert.get("window_end"),
                evidence_file,
                1 if alert.get("evidence_truncated") else 0,
                int(messages),
                1 if delivered else 0,
                iso(),
            ),
        )
        if cur.rowcount == 0:
            return None
        alert_id = int(cur.lastrowid)
        rows = [
            tuple(
                [alert_id]
                + [
                    int(h.get(f) or 0) if f == "line" else (h.get(f) or None)
                    for f in _HIT_FIELDS
                ]
            )
            for h in hits
            if isinstance(h, dict)
        ]
        if rows:
            conn.executemany(
                "INSERT INTO alert_hits (alert_id, rule_id, severity, source, file, line,"
                " ip, method, uri, status, ua, pid, raw, ts_utc)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows,
            )
        return alert_id


def recent_alerts(db_path: str, limit: int = 20, project_id: Optional[int] = None,
                  device_id: Optional[int] = None, severity: Optional[str] = None) -> list:
    q = (
        "SELECT a.*, p.project_name, d.device_name FROM alerts a"
        " JOIN projects p ON p.id = a.project_id"
        " JOIN devices d ON d.id = a.device_id"
    )
    where, args = [], []
    if project_id is not None:
        where.append("a.project_id = ?")
        args.append(project_id)
    if device_id is not None:
        where.append("a.device_id = ?")
        args.append(device_id)
    if severity:
        where.append("a.severity = ?")
        args.append(severity.upper())
    if where:
        q += " WHERE " + " AND ".join(where)
    q += " ORDER BY a.id DESC LIMIT ?"
    args.append(int(limit))
    with connect(db_path) as conn:
        return conn.execute(q, args).fetchall()


def alert_detail(db_path: str, alert_id: int, project_id: Optional[int] = None) -> Optional[dict]:
    """One alert + all its hits. `project_id` limits the lookup to that project."""
    q = (
        "SELECT a.*, p.project_name, d.device_name FROM alerts a"
        " JOIN projects p ON p.id = a.project_id"
        " JOIN devices d ON d.id = a.device_id WHERE a.id = ?"
    )
    args: list[Any] = [alert_id]
    if project_id is not None:
        q += " AND a.project_id = ?"
        args.append(int(project_id))
    with connect(db_path) as conn:
        row = conn.execute(q, args).fetchone()
        if row is None:
            return None
        hits = conn.execute(
            "SELECT rule_id, severity, source, file, line, ip, method, uri, status,"
            " ua, pid, raw, ts_utc FROM alert_hits WHERE alert_id = ? ORDER BY id",
            (alert_id,),
        ).fetchall()
    out = dict(row)
    out["rules"] = json.loads(out.get("rules") or "[]")
    out["evidence"] = [dict(h) for h in hits]
    return out


def search_hits(db_path: str, q: str, limit: int = 100,
                project_id: Optional[int] = None) -> list:
    """Free-text search over raw hit lines (forensics: IP, URI, file...)."""
    sql = (
        "SELECT h.*, a.batch_id, a.severity AS alert_severity, a.received_at,"
        " d.device_name, p.project_name"
        " FROM alert_hits h"
        " JOIN alerts a ON a.id = h.alert_id"
        " JOIN devices d ON d.id = a.device_id"
        " JOIN projects p ON p.id = a.project_id"
        " WHERE (h.raw LIKE ? OR h.file LIKE ? OR h.ip LIKE ? OR h.uri LIKE ?)"
    )
    args: list[Any] = [f"%{q}%"] * 4
    if project_id is not None:
        sql += " AND a.project_id = ?"
        args.append(int(project_id))
    sql += " ORDER BY h.id DESC LIMIT ?"
    args.append(int(limit))
    with connect(db_path) as conn:
        return conn.execute(sql, args).fetchall()


def stats(db_path: str, project_id: Optional[int] = None) -> list:
    """Per project/device counters (total alerts, last seen, last severity)."""
    sql = (
        "SELECT p.project_name, d.device_name, d.last_seen_at,"
        " COUNT(a.id) AS alerts,"
        " COALESCE(SUM(a.hit_count), 0) AS hits,"
        " (SELECT a2.severity FROM alerts a2 WHERE a2.device_id = d.id"
        "  ORDER BY a2.id DESC LIMIT 1) AS last_severity,"
        " (SELECT a3.received_at FROM alerts a3 WHERE a3.device_id = d.id"
        "  ORDER BY a3.id DESC LIMIT 1) AS last_alert_at"
        " FROM devices d JOIN projects p ON p.id = d.project_id"
        " LEFT JOIN alerts a ON a.device_id = d.id"
    )
    args: list[Any] = []
    if project_id is not None:
        sql += " WHERE p.id = ?"
        args.append(int(project_id))
    sql += " GROUP BY d.id ORDER BY p.project_name, d.device_name"
    with connect(db_path) as conn:
        return conn.execute(sql, args).fetchall()


# ---------------------------------------------------------------- retention

def cleanup(db_path: str, reveal_ttl_sec: int, retention_days: int = 0) -> None:
    """Drop expired pairing codes/keys and (optionally) alerts past retention."""
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
                conn.execute("UPDATE pairing_codes SET api_key_plain = NULL WHERE code = ?",
                             (r["code"],))
        if retention_days > 0:
            cut = iso(now - timedelta(days=retention_days))
            conn.execute("DELETE FROM alerts WHERE received_at < ?", (cut,))
