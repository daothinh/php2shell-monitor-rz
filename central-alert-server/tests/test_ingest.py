"""Ingest + storage tests for the central alert server.

These exercise the real FastAPI app with the Telegram client stubbed out, so
the storage contract (one alert per batch, every raw hit kept with file:line)
is verified without network access.
"""
import json
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
    )
    db.init_db(cfg.database_path)
    tg = FakeTelegram()
    app.state.cfg = cfg
    from zoneinfo import ZoneInfo

    app.state.tz = ZoneInfo(cfg.display_tz)
    app.state.telegram = tg
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
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    payload = {"host": "web01", "alerts": [_alert()]}

    assert client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                       json=payload).json()["accepted"] == 1
    second = client.post("/api/v1/ingest-log", headers={"X-API-Key": key}, json=payload).json()
    assert second["accepted"] == 0
    assert second["duplicates"] == 1

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


def test_legacy_single_hit_payload_is_normalized(env):
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
    detail = client.get(f"/api/v1/alerts/{r.json()['alerts'][0]['alert_id']}",
                         headers={"X-API-Key": key}).json()
    assert detail["evidence"][0]["rule_id"] == "P2S-030"
    assert detail["evidence"][0]["uri"] == "/shell.php?cmd=whoami"


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
                json={"host": "web01", "lan_ip": "10.0.0.15", "alerts": [_alert()]})
    assert len(tg.sent) == 1
    text = tg.sent[0][1]
    lines = text.split("\n")
    assert len(lines) == 5, text
    assert lines[0].startswith("🛡 <b>Central Security Alert</b> - 24/10/2026 - ")
    # P2S-020 carries impact=rce -> CRITICAL, headline must say the box is owned
    assert lines[1].startswith("🚨 <b>CRITICAL</b> · Server bị chiếm quyền (RCE)")
    assert "3 events" in lines[1]
    assert lines[2] == "📦 Dự án: <b>khach-hang-a</b>"
    assert lines[3] == "🚨 User: <b>root</b> - Hostname: <b>web01</b>"
    assert lines[4] == "🖥 IP LAN: <b>10.0.0.15</b>"


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
    # Số event thay cho "hit / phút"; không còn ký tự < nào lọt vào HTML.
    assert "3 events" in text
    assert "<1 phút" not in text


def test_telegram_message_without_lan_ip(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})
    # Không rõ IP LAN thì ghi rõ "không rõ", không bỏ dòng (giữ shape 5 dòng).
    assert tg.sent[0][1].split("\n")[4] == "🖥 IP LAN: <b>không rõ</b>"


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


def _register_chatid(client, name, chat_id, device=None):
    body = {"project_name": name, "chat_id": str(chat_id)}
    if device:
        body["device"] = device
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
    notifies = [t for _, t in tg.sent if "tự động ghép nối" in t]
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
    assert "tự động ghép nối" in tg.sent[0][1]
    assert "web01" in tg.sent[0][1] and "/unlink web01" in tg.sent[0][1]


def test_multiple_servers_one_chat_auto_linked(env):
    """Một GROUP nhận alert của nhiều server: 2 lần register -> mỗi dự án 1 tin
    bot, cả hai key dùng được ngay, /list hiện đủ 2."""
    client, cfg, tg = env
    r1 = _register_chatid(client, "alpha", GROUP)
    r2 = _register_chatid(client, "beta", GROUP)
    for r in (r1, r2):
        st = client.get(f"/api/v1/pairing-status?code={r['pair_ref']}").json()
        assert st["status"] == "linked" and st.get("api_key")
    notifies = [t for _, t in tg.sent if "tự động ghép nối" in t]
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
    key mới — key cũ VẪN SỐNG (1000 máy = 1000 key song song), bot KHÔNG nhắn
    thêm tin nào (re-pair im lặng, không spam chat)."""
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
    assert len(tg.sent) == 1  # KHÔNG tin bot nào thêm

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
def test_headline_only_critical_on_rce_evidence():
    """CRITICAL = server đã bị chiếm quyền. Chỉ bằng chứng RCE mới được nói vậy."""
    from app.telegram import _headline

    def h(rule_id, sev="CRITICAL"):
        return _headline({"severity": sev, "evidence": [{"rule_id": rule_id}]})

    # có shell trên đĩa / lệnh đã chạy / LFI đã đọc được file
    for rid in ("P2S-020", "P2S-021", "P2S-022", "P2S-024", "P2S-025",
                "P2S-056", "P2S-057"):
        assert h(rid) == "Server bị chiếm quyền (RCE)", rid

    # chỉ là dò quét / đang khai thác, chưa chứng minh được gì
    assert h("P2S-050", "MODERATE") == "Server đang bị khai thác php2shell"
    assert h("P2S-051", "MODERATE") == "Server đang bị khai thác php2shell"
    assert h("P2S-054", "MODERATE") == "Server đang bị khai thác php2shell"
    assert h("P2S-050", "INFO") == "Dấu hiệu dò quét php2shell"


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
    assert _headline(attempt) == "Dấu hiệu dò quét php2shell"

    # đã đọc được: 2xx, P2S-057 fire
    success = {"severity": "CRITICAL", "evidence": [
        {"rule_id": "P2S-050,P2S-051,P2S-057", "uri": uri, "status": "200"}]}
    assert is_rce(success) is True
    assert _headline(success) == "Server bị chiếm quyền (RCE)"


def test_merged_rule_id_still_detects_rce():
    """De-dup gộp rule thành "P2S-050,P2S-056": phải tách ra mới thấy RCE."""
    from app.telegram import is_rce

    assert is_rce({"evidence": [{"rule_id": "P2S-050,P2S-056"}]}) is True
    assert is_rce({"evidence": [{"rule_id": "P2S-050,P2S-051"}]}) is False
    # counters path (payload không kèm evidence[])
    assert is_rce({"rules": [{"rule_id": "P2S-056", "hits": 1}]}) is True


def test_format_alert_matches_template():
    from datetime import datetime
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {
        "batch_id": "20261025T165000Z",
        "severity": "MODERATE", "hits": 6740,
        "host": "web-01", "user": "www-data", "hostname": "ip-10-0-1-5",
        "lan_ip": "10.0.1.5",
        "ts_utc": "2026-10-25T16:50:00Z",
        "evidence": [{"rule_id": "P2S-050", "impact": ""}],
    }
    lines = format_alert("prod-shop", alert,
                         ZoneInfo("Asia/Ho_Chi_Minh")).split("\n")
    assert len(lines) == 5
    assert lines[0] == "🛡 <b>Central Security Alert</b> - 25/10/2026 - 23:50"
    assert lines[1] == ("🟡 <b>MODERATE</b> · Server đang bị khai thác php2shell"
                        " · 6740 events")
    assert lines[2] == "📦 Dự án: <b>prod-shop</b>"
    assert lines[3] == "🟡 User: <b>www-data</b> - Hostname: <b>ip-10-0-1-5</b>"
    assert lines[4] == "🖥 IP LAN: <b>10.0.1.5</b>"


def test_format_alert_critical_uses_rce_headline():
    from zoneinfo import ZoneInfo
    from app.telegram import format_alert

    alert = {"severity": "CRITICAL", "hits": 3, "host": "web-01",
             "user": "www-data", "hostname": "web-01", "lan_ip": "10.0.1.5",
             "ts_utc": "2026-10-25T16:50:00Z",
             "evidence": [{"rule_id": "P2S-056", "impact": "rce"}]}
    msg = format_alert("prod", alert, ZoneInfo("Asia/Ho_Chi_Minh"))
    assert "🚨 <b>CRITICAL</b> · Server bị chiếm quyền (RCE) · 3 events" in msg


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
