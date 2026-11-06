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
alerts      one row per batch alert (severity = CRITICAL only on RCE evidence,
            MODERATE at >=5000 events, INFO below)
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
    -- Envelope của thiết bị tại thời điểm alert: cần để dựng lại/gửi lại tin
    -- (resend) mà không phải đoán từ đường dẫn evidence.
    lan_ip TEXT, hostname TEXT, user TEXT, os TEXT, env TEXT,
    UNIQUE(device_id, batch_id)            -- agent retries must not duplicate
);

-- reported_events: event ĐÃ gửi Telegram, để batch sau không báo lại.
-- Khoá là sha256(source|file|line|raw) chứ không phải (batch, id) vì chính
-- nội dung sự kiện mới là thứ người trực ca không muốn đọc hai lần.
CREATE TABLE IF NOT EXISTS reported_events (
    device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    ident     TEXT NOT NULL,
    alert_id  INTEGER NOT NULL DEFAULT 0,
    source    TEXT,
    file      TEXT,
    line      INTEGER NOT NULL DEFAULT 0,
    sent_at   TEXT NOT NULL,
    PRIMARY KEY (device_id, ident)
);
CREATE INDEX IF NOT EXISTS idx_reported_sent ON reported_events(sent_at);

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

CREATE TABLE IF NOT EXISTS api_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    key_hash TEXT UNIQUE NOT NULL,          -- sha256(api_key); mỗi lần pair CẤP THÊM key,
    label TEXT,                             -- key cũ vẫn sống: 1000 máy = 1000 key song song
    created_at TEXT NOT NULL,
    last_used_at TEXT,
    active INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_pairing_project ON pairing_codes(project_id);
CREATE INDEX IF NOT EXISTS idx_devices_project ON devices(project_id);
CREATE INDEX IF NOT EXISTS idx_keys_project    ON api_keys(project_id, active);
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
        # Envelope trên bảng alerts: thêm cột cho DB tạo trước bản vá.
        have = {r["name"] for r in conn.execute("PRAGMA table_info(alerts)")}
        for col in ("lan_ip", "hostname", "user", "os", "env"):
            if col not in have:
                conn.execute(f"ALTER TABLE alerts ADD COLUMN {col} TEXT")
        # containers: JSON array tên container gây alert. Thiếu cột này thì alert
        # đã lưu (và mọi tin gửi bù / gửi lại) MẤT dòng 🐳 Container — đường
        # ingest gửi trực tiếp thì còn, nên lỗi chỉ hiện ở đúng những alert quan
        # trọng nhất: alert bị hoãn rồi gửi bù khi evidence lên tới server.
        if "containers" not in have:
            conn.execute("ALTER TABLE alerts ADD COLUMN containers TEXT")
        # Migrate (một lần, idempotent): key duy nhất cũ trên projects ->
        # thành 1 row trong api_keys; từ đó mỗi lần pair cấp thêm key mới.
        conn.execute(
            """
            INSERT INTO api_keys (project_id, key_hash, label, created_at)
            SELECT p.id, p.api_key_hash, 'legacy', ?
            FROM projects p
            WHERE p.api_key_hash IS NOT NULL AND p.status = 'linked'
              AND NOT EXISTS (SELECT 1 FROM api_keys k WHERE k.project_id = p.id)
            """,
            (iso(),),
        )


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

def create_project(db_path: str, name: str, telegram_chat_id: Optional[str] = None,
                   device_label: str = "") -> int:
    """Project pending; telegram_chat_id khi có là CHAT ĐÍCH script yêu cầu ghép.

    Ba trường hợp, phân biệt bằng DEVICE:

    1. Đúng cặp (tên, chat) đã có            -> tái dùng row (re-pair idempotent).
    2. Cùng tên + CÙNG device, khác chat     -> CHUYỂN row sang chat mới, giữ
       nguyên project_id nên toàn bộ lịch sử alert đi theo. Đây là "đổi nơi
       nhận alert" (group <-> chat riêng) của cùng một máy.
    3. Cùng tên + device KHÁC (hoặc không rõ) -> tạo row riêng.

    Vì sao trường hợp 3 không gộp: hai khách hàng khác nhau hoàn toàn có thể
    cùng đặt tên dự án "web" và cùng có hostname "web01". Gộp chúng lại sẽ đẩy
    alert của khách này sang chat của khách kia — sự cố bảo mật, không phải bất
    tiện. Không có bằng chứng "cùng một máy" thì không gộp.

    Trước đây chỉ có trường hợp 1 và 3, nên đổi chat sinh row thứ hai cùng tên:
    /list hiện dự án hai lần, lịch sử tách đôi.
    """
    with _WRITE_LOCK, connect(db_path) as conn:
        if telegram_chat_id is not None:
            chat = str(telegram_chat_id)
            # 1. đúng cặp (tên, chat) đã có -> tái dùng
            row = conn.execute(
                "SELECT id FROM projects"
                " WHERE project_name = ? AND telegram_chat_id = ?"
                " ORDER BY id LIMIT 1",
                (name, chat),
            ).fetchone()
            if row is not None:
                return int(row["id"])
            # 2. cùng tên + CÙNG device, chat khác -> chuyển row sang chat mới.
            dev = slug(device_label) if (device_label or "").strip() else ""
            if dev:
                row = conn.execute(
                    "SELECT p.id FROM projects p"
                    "  JOIN devices d ON d.project_id = p.id"
                    " WHERE p.project_name = ? AND d.device_name = ?"
                    " ORDER BY (p.status = 'linked') DESC, p.id LIMIT 1",
                    (name, dev),
                ).fetchone()
                if row is not None:
                    conn.execute(
                        "UPDATE projects SET telegram_chat_id = ? WHERE id = ?",
                        (chat, int(row["id"])),
                    )
                    log.info("chuyển dự án %s (thiết bị %s) sang chat %s — giữ"
                             " nguyên lịch sử alert của row %s",
                             name, dev, chat, row["id"])
                    return int(row["id"])
        cur = conn.execute(
            "INSERT INTO projects (project_name, status, created_at, telegram_chat_id)"
            " VALUES (?, 'pending', ?, ?)",
            (name, iso(), telegram_chat_id),
        )
        return int(cur.lastrowid)


def pending_codes_by_chat_id(db_path: str, chat_id: str) -> list[sqlite3.Row]:
    """Các mã pairing còn hiệu lực của mọi project CHỜ /confirm theo chat ID.
    Một chat (user hoặc group) có thể có nhiều server đang chờ cùng lúc.
    Không lọc theo status của project: dự án ĐÃ linked pair lại (xoay key/
    thêm máy) cũng có code chờ /confirm như dự án mới."""
    with connect(db_path) as conn:
        return conn.execute(
            """
            SELECT pc.code, p.project_name, p.id AS project_id
            FROM pairing_codes pc
            JOIN projects p ON p.id = pc.project_id
            WHERE p.telegram_chat_id = ?
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
    """Auth theo bảng api_keys (nhiều key song song/dự án); cập nhật last_used."""
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute(
            "UPDATE api_keys SET last_used_at = ? WHERE key_hash = ? AND active = 1",
            (iso(), key_hash),
        )
        return conn.execute(
            """
            SELECT p.* FROM api_keys k
            JOIN projects p ON p.id = k.project_id
            WHERE k.key_hash = ? AND k.active = 1 AND p.status = 'linked'
            """,
            (key_hash,),
        ).fetchone()


def api_key_owner(db_path: str, key_hash: str) -> Optional[sqlite3.Row]:
    """Tra dự án sở hữu key hash BẤT KỂ trạng thái (active, project.status).

    KHÔNG dùng để xác thực — chỉ để phân loại lỗi 401 (key chưa từng tồn tại
    khác với dự án đã bị /unlink) và trả /whoami, để agent phía máy phân biệt
    "phải pair lại" với "thử lại sau".
    """
    with connect(db_path) as conn:
        return conn.execute(
            """
            SELECT p.* FROM api_keys k
            JOIN projects p ON p.id = k.project_id
            WHERE k.key_hash = ?
            ORDER BY k.active DESC, k.id DESC LIMIT 1
            """,
            (key_hash,),
        ).fetchone()


def count_projects(db_path: str) -> int:
    with connect(db_path) as conn:
        return conn.execute("SELECT COUNT(*) AS n FROM projects").fetchone()["n"]


def projects_by_chat(db_path: str, chat_id: str) -> list[sqlite3.Row]:
    """Mọi project ĐANG GHÉP với MỘT chat Telegram — một người, nhiều server/dự án.
    Chỉ status='linked': dự án đã /unlink không hiện trong /list."""
    with connect(db_path) as conn:
        return conn.execute(
            """
            SELECT p.id, p.project_name, p.status, p.linked_at,
                   (SELECT COUNT(*) FROM devices d WHERE d.project_id = p.id) AS device_count,
                   (SELECT MAX(a.received_at) FROM alerts a WHERE a.project_id = p.id)
                       AS last_alert_at
            FROM projects p
            WHERE p.telegram_chat_id = ? AND p.status = 'linked'
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


def auto_link_code(db_path: str, code: str, gen_api_key, key_hash,
                   device_label: str = "") -> dict:
    """Ghép nối TỰ ĐỘNG (không /confirm): dùng code ngay khi script đăng ký,
    cấp THÊM một API key mới vào api_keys (các key cũ vẫn sống). Trả về
    newly_linked=True khi đây là lần liên kết đầu của dự án với chat (để bot
    chỉ thông báo 1 tin cho dự án mới, re-pair im lặng)."""
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
        newly_linked = row["status"] != "linked"
        api_key = gen_api_key()
        if newly_linked:
            conn.execute(
                "UPDATE projects SET status = 'linked', linked_at = ? WHERE id = ?",
                (now, row["id"]),
            )
        conn.execute(
            "INSERT INTO api_keys (project_id, key_hash, label, created_at)"
            " VALUES (?, ?, ?, ?)",
            (row["id"], key_hash(api_key), (device_label or "")[:64], now),
        )
        # Register the device NOW, not on first alert. Pairing is the moment a
        # machine joins the project, so /list must count it immediately: waiting
        # for ingest meant a freshly paired box showed as "chưa khả dụng" until
        # it happened to produce an alert, which may be never.
        # slug("") returns "unknown", which would create a phantom device for
        # every caller that pairs without a hostname. Only register a real one.
        dev = slug(device_label) if (device_label or "").strip() else ""
        if dev:
            conn.execute(
                "INSERT INTO devices (project_id, device_name, created_at, last_seen_at)"
                " VALUES (?, ?, ?, ?)"
                " ON CONFLICT(project_id, device_name) DO NOTHING",
                (row["id"], dev, now, now),
            )
        conn.execute(
            "UPDATE pairing_codes SET used_at = ?, api_key_plain = ? WHERE code = ?",
            (now, api_key, code.upper()),
        )
        return {"project_id": row["id"], "project_name": row["project_name"],
                "api_key": api_key, "newly_linked": newly_linked}


def unlink_project(db_path: str, project_name: str, chat_id: str) -> Optional[str]:
    """/unlink: ngắt một dự án khỏi chat (status=disabled) và THU HỒI toàn bộ
    API key của dự án (active=0). Alert dừng gửi, key trong conf trên các máy
    chết hẳn — agent gọi /whoami hoặc bị 401 sẽ biết phải chạy deploy lại để
    ghép nối lại (lúc đó auto_link cấp key mới). Lịch sử alert giữ nguyên.
    Trả về tên dự án đã ngắt, None nếu không tìm thấy."""
    with _WRITE_LOCK, connect(db_path) as conn:
        row = conn.execute(
            "SELECT id FROM projects"
            " WHERE project_name = ? AND telegram_chat_id = ? AND status = 'linked'",
            (project_name, str(chat_id)),
        ).fetchone()
        if row is None:
            return None
        conn.execute("UPDATE projects SET status = 'disabled' WHERE id = ?",
                     (int(row["id"]),))
        conn.execute("UPDATE api_keys SET active = 0 WHERE project_id = ?",
                     (int(row["id"]),))
        return project_name


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
    # Trạng thái đi theo VÒNG ĐỜI CODE, không theo project: dự án đã linked
    # pair lại vẫn "pending" cho tới khi /confirm dùng code này — agent không
    # bỏ cuộc sớm khi thấy linked mà chưa có key.
    if row["used_at"] and row["p_status"] == "linked":
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
            " evidence_truncated, messages, delivered, received_at,"
            " lan_ip, hostname, user, os, env, containers)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
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
                alert.get("lan_ip") or None,
                alert.get("hostname") or alert.get("host") or None,
                alert.get("user") or None,
                alert.get("os") or None,
                alert.get("env") or None,
                json.dumps(alert.get("containers") or [], ensure_ascii=False)
                if alert.get("containers") else None,
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


def chat_id_of_project(db_path: str, project_id: int) -> str:
    with connect(db_path) as conn:
        row = conn.execute("SELECT telegram_chat_id FROM projects WHERE id = ?",
                           (int(project_id),)).fetchone()
    return str(row["telegram_chat_id"] or "") if row else ""


def alert_hits_rows(db_path: str, alert_id: int) -> list:
    """Các hit đã lưu của alert, dạng dict (nguồn raw dự phòng khi mất file)."""
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT rule_id, severity, source, file, line, ip, method, uri,"
            " status, ua, pid, raw, ts_utc FROM alert_hits"
            " WHERE alert_id = ? AND raw IS NOT NULL AND raw <> '' ORDER BY id",
            (int(alert_id),),
        ).fetchall()
    return [dict(r) for r in rows]


def alerts_awaiting_raw(db_path: str, limit: int = 200,
                        max_age_sec: int = 3600) -> list:
    """Alert đã lưu nhưng CHƯA gửi Telegram (messages=0) vì thiếu raw event.

    Đây là hàng đợi gửi bù: /ingest-evidence và vòng cleanup gọi lại, dựng
    preview[] từ evidence mirror rồi gửi đúng một tin.

    GIỚI HẠN TUỔI (max_age_sec, mặc định 1 giờ) là bắt buộc, không phải tối ưu:
    một alert tồn đọng từ lâu — hàng đợi của bản cũ, DB phục hồi từ backup, hay
    alert mà agent không bao giờ upload evidence — nếu không có trần thời gian
    thì khi server được update, hàng đợi sẽ bắn lại toàn bộ sự kiện CŨ vào chat
    của khách. Người trực ca nhận một loạt cảnh báo của tuần trước và mất niềm
    tin vào kênh. Quá hạn thì alert vẫn nằm trong DB để tra cứu, nhưng KHÔNG
    gửi: nghiệp vụ là cảnh báo sự kiện đang diễn ra, không phải phát lại lịch sử.
    """
    cut = iso(utcnow() - timedelta(seconds=int(max_age_sec)))
    with connect(db_path) as conn:
        return conn.execute(
            "SELECT a.*, p.project_name, p.telegram_chat_id, d.device_name"
            "  FROM alerts a"
            "  JOIN projects p ON p.id = a.project_id"
            "  JOIN devices d ON d.id = a.device_id"
            " WHERE a.messages = 0 AND p.status = 'linked'"
            "   AND p.telegram_chat_id IS NOT NULL AND p.telegram_chat_id <> ''"
            "   AND a.received_at >= ?"
            " ORDER BY a.id LIMIT ?",
            (cut, int(limit)),
        ).fetchall()


def expire_stale_unsent(db_path: str, max_age_sec: int = 3600) -> int:
    """Đánh dấu alert tồn đọng quá hạn là "đã xử lý" để không bao giờ gửi lại.

    Đặt messages=2 (không phải 1) để phân biệt rõ trong DB:
      messages=0 -> đang chờ gửi bù (còn trong cửa sổ)
      messages=1 -> đã gửi (delivered cho biết Telegram có nhận không)
      messages=2 -> hết hạn, cố ý KHÔNG gửi (alert cũ / agent không upload)
    """
    cut = iso(utcnow() - timedelta(seconds=int(max_age_sec)))
    with _WRITE_LOCK, connect(db_path) as conn:
        cur = conn.execute(
            "UPDATE alerts SET messages = 2 WHERE messages = 0 AND received_at < ?",
            (cut,),
        )
        return int(cur.rowcount or 0)


def mark_alert_sent(db_path: str, alert_id: int, delivered: bool,
                    evidence_file: str = "") -> None:
    """Ghi nhận đã gửi (hoặc gửi lỗi) cho alert đang chờ."""
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute(
            "UPDATE alerts SET messages = 1, delivered = ?,"
            " evidence_file = COALESCE(NULLIF(?, ''), evidence_file)"
            " WHERE id = ?",
            (1 if delivered else 0, evidence_file or "", int(alert_id)),
        )


# ---------------------------------------------------- dedup event đã báo

def reported_idents(db_path: str, device_id: int, idents: list,
                    window_sec: int) -> set:
    """Các ident trong `idents` đã được báo cho thiết bị này trong cửa sổ."""
    if not idents:
        return set()
    cut = iso(utcnow() - timedelta(seconds=int(window_sec)))
    out: set = set()
    with connect(db_path) as conn:
        # chia lô: SQLite giới hạn số tham số (999 mặc định)
        for i in range(0, len(idents), 400):
            part = idents[i:i + 400]
            ph = ",".join("?" * len(part))
            rows = conn.execute(
                f"SELECT ident FROM reported_events WHERE device_id = ?"
                f" AND sent_at >= ? AND ident IN ({ph})",
                [int(device_id), cut] + list(part),
            ).fetchall()
            out.update(r["ident"] for r in rows)
    return out


def record_reported_events(db_path: str, rows: list) -> int:
    """Ghi (device_id, ident, alert_id, source, file, line) vào reported_events."""
    if not rows:
        return 0
    now = iso()
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.executemany(
            "INSERT OR REPLACE INTO reported_events"
            " (device_id, ident, alert_id, source, file, line, sent_at)"
            " VALUES (?,?,?,?,?,?,?)",
            [(int(d), str(i), int(a), s, f, int(ln), now)
             for (d, i, a, s, f, ln) in rows],
        )
    return len(rows)


def prune_reported_events(db_path: str, window_sec: int) -> int:
    """Xoá ident quá cửa sổ — bảng phải có trần, không phình mãi."""
    cut = iso(utcnow() - timedelta(seconds=int(window_sec)))
    with _WRITE_LOCK, connect(db_path) as conn:
        cur = conn.execute("DELETE FROM reported_events WHERE sent_at < ?", (cut,))
        return int(cur.rowcount or 0)


def mark_alert_suppressed(db_path: str, alert_id: int) -> None:
    """Đánh dấu alert đã lưu nhưng CỐ Ý không gửi vì mọi event đã báo trước.

    Dùng messages=2 (cùng giá trị với "hết hạn gửi bù"), khác hẳn messages=0
    ("đang chờ gửi bù"). Nếu để 0, cleanup loop sẽ nhặt lại và gửi đúng cái vừa
    bị chặn — biến dedup thành vô nghĩa.
    """
    with _WRITE_LOCK, connect(db_path) as conn:
        conn.execute("UPDATE alerts SET messages = 2 WHERE id = ?",
                     (int(alert_id),))


def hits_present(db_path: str, alert_id: int) -> int:
    """Số row alert_hits có raw THẬT (không phải row rác rule_id=NULL)."""
    with connect(db_path) as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM alert_hits"
            " WHERE alert_id = ? AND raw IS NOT NULL AND raw <> ''",
            (int(alert_id),),
        ).fetchone()
    return int(row["n"] or 0)


def alert_id_for_device_batch(db_path: str, device_id: int,
                              batch_id: str) -> Optional[int]:
    """id của alert đã lưu cho (device, batch) — đúng khoá UNIQUE của bảng.

    Dùng để chặn gửi trùng TRƯỚC khi gọi Telegram: agent retry sau lỗi mạng
    không được sinh tin thứ hai cho cùng một batch.
    """
    if not batch_id:
        return None
    with connect(db_path) as conn:
        row = conn.execute(
            "SELECT id FROM alerts WHERE device_id = ? AND batch_id = ?",
            (int(device_id), str(batch_id)),
        ).fetchone()
    return int(row["id"]) if row else None


def alert_by_batch(db_path: str, project_id: int, batch_id: str) -> Optional[sqlite3.Row]:
    with connect(db_path) as conn:
        return conn.execute(
            "SELECT a.*, d.device_name FROM alerts a JOIN devices d ON d.id = a.device_id"
            " WHERE a.project_id = ? AND a.batch_id = ?",
            (int(project_id), str(batch_id)),
        ).fetchone()


def backfill_hits(db_path: str, alert_id: int, records, cap: int = 2000) -> int:
    """Nạp alert_hits từ raw event cho một alert đang KHÔNG có hit thật.

    Alert do monitor <= 1.4.2 gửi lên mang evidence[] rỗng (raw đi kênh riêng),
    nên trước bản vá DB chỉ có một row rác và /search mù hoàn toàn. Hàm này đọc
    lại file evidence đã mirror và dựng các row thật — idempotent: alert đã có
    raw thì không làm gì.

    Trả về số row đã thêm. `cap` chặn một batch 363k dòng làm nghẽn DB; phần
    vượt cap vẫn nằm nguyên trong file evidence (nguồn sự thật).
    """
    rows = []
    for h in records:
        if not isinstance(h, dict):
            continue
        rows.append(tuple(
            [int(alert_id)] + [
                int(h.get(f) or 0) if f == "line" else (h.get(f) or None)
                for f in _HIT_FIELDS
            ]
        ))
        if len(rows) >= cap:
            break
    if not rows:
        return 0
    with _WRITE_LOCK, connect(db_path) as conn:
        have = conn.execute(
            "SELECT COUNT(*) AS n FROM alert_hits"
            " WHERE alert_id = ? AND raw IS NOT NULL AND raw <> ''",
            (int(alert_id),),
        ).fetchone()["n"]
        if have:
            return 0
        conn.execute("DELETE FROM alert_hits WHERE alert_id = ? AND raw IS NULL",
                     (int(alert_id),))
        conn.executemany(
            "INSERT INTO alert_hits (alert_id, rule_id, severity, source, file, line,"
            " ip, method, uri, status, ua, pid, raw, ts_utc)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            rows,
        )
        conn.execute("UPDATE alerts SET evidence_truncated = 1 WHERE id = ?"
                     " AND hit_count > ?", (int(alert_id), len(rows)))
    return len(rows)


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
        # reported_events: dọn theo retention (window dedup ngắn hơn nhiều nên
        # dùng chung trần là đủ rộng rãi, không cần tham số riêng).
        keep = retention_days if retention_days > 0 else 7
        conn.execute("DELETE FROM reported_events WHERE sent_at < ?",
                     (iso(now - timedelta(days=keep)),))
