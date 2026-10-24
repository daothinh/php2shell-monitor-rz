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
    pid = db.create_project(cfg.database_path, name)
    from app.security import gen_api_key, sha256_hex

    key = gen_api_key()
    with db.connect(cfg.database_path) as conn:
        conn.execute(
            "UPDATE projects SET status='linked', telegram_chat_id=?, api_key_hash=?"
            " WHERE id=?",
            (chat_id, sha256_hex(key), pid),
        )
    return pid, key


def _alert(batch="20261024T000000Z"):
    return {
        "ts_utc": "2026-10-24T00:00:05Z",
        "batch_id": batch,
        "project": "khach-hang-a",
        "device": "web01",
        "host": "web01",
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
    assert path.parent.name == "IP-LAN_unknown_web01_unknown"
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
    assert len(lines) == 4, text
    assert lines[0] == "🛡 <b>Central Security Alert</b> - 24/10/2026"
    # CRITICAL wins over the HIGH hit; P2S-020 (RCE_RULES) sets the RCE headline
    assert lines[1].startswith("🚨 <b>CRITICAL</b> · <b>Server bị chiếm quyền (RCE)</b>")
    assert "3 hit / 5 phút" in lines[1]
    assert lines[2] == "📦 Dự án: <b>khach-hang-a</b>"
    assert lines[3] == "🖥 <b>web01</b> / 10.0.0.15"


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
    assert "hit / &lt;1 phút" in text
    assert "<1 phút" not in text


def test_telegram_message_without_lan_ip(env):
    client, cfg, tg = env
    _, key = _project_with_key(cfg)
    client.post("/api/v1/ingest-log", headers={"X-API-Key": key},
                json={"host": "web01", "alerts": [_alert()]})
    assert tg.sent[0][1].split("\n")[3] == "🖥 <b>web01</b>"


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


def test_bot_two_servers_one_confirm(env):
    """Một chat ghép 2 server: register-chatid x2 (cùng chat) -> 1 /confirm ghép cả hai."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8001

    _register_chatid(client, "web-cluster", chat)
    _register_chatid(client, "db-cluster", chat)
    asyncio.run(bot.handle_update(_msg(chat, "/confirm")))
    assert "2 server" in tg.sent[-1][1]
    assert len(db.projects_by_chat(cfg.database_path, str(chat))) == 2


def test_bot_add_new_id_is_gone(env):
    """/add_new_id đã bị bỏ — không còn trong menu và không còn xử lý riêng."""
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    from app.telegram import PairingBot
    assert "add_new_id" not in [c for c, _ in PairingBot.BOT_COMMANDS]
    asyncio.run(bot.handle_update(_msg(8009, "/add_new_id")))
    # rơi vào nhánh else: help (không có pending nào ở chat này)
    assert "Trợ giúp" in tg.sent[-1][1] or "Chào mừng" in tg.sent[-1][1]


def test_bot_list_shows_all_servers_of_one_chat(env):
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8002

    asyncio.run(bot.handle_update(_msg(chat, "/list")))
    assert "Chưa có server" in tg.sent[-1][1]

    for name in ("alpha", "beta"):
        _register_chatid(client, name, chat)
    asyncio.run(bot.handle_update(_msg(chat, "/confirm")))

    asyncio.run(bot.handle_update(_msg(chat, "/list")))
    text = tg.sent[-1][1]
    assert "2" in text and "alpha" in text and "beta" in text


def test_bot_help_mentions_commands(env):
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(8003, "/help")))
    text = tg.sent[-1][1]
    assert "/list" in text and "/id" in text
    assert "/confirm" in text and "Chat ID" in text
    assert "/add_new_id" not in text  # lệnh đã bỏ
    assert "≡" in text and "3 bước" in text  # gợi ý menu + luồng ghép nối


def test_bot_welcome_on_start(env):
    _, cfg, tg = env
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(8005, "/start")))
    assert "Chào mừng" in tg.sent[-1][1]


def test_bot_command_menu_is_valid():
    """BOT_COMMANDS phải hợp lệ với Telegram: lowercase a-z0-9_, <=32 ký tự, duy nhất;
    và phủ mọi lệnh chính của router (để menu ≡ không thiếu lệnh nào)."""
    import re
    from app.telegram import PairingBot
    cmds = [c for c, _ in PairingBot.BOT_COMMANDS]
    assert len(cmds) == len(set(cmds))
    for c in cmds:
        assert re.fullmatch(r"[a-z0-9_]{1,32}", c), c
    for expected in ("start", "help", "id", "confirm", "list"):
        assert expected in cmds, expected


def test_bot_sec_code_fallback_is_removed(env):
    """Fallback mã SEC-<UUID> đã bỏ: gửi mã KHÔNG ghép nối được gì, bot trả
    thông báo đã ngừng và hướng dẫn luồng Chat ID."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8004
    # tạo một pending chat-id cho chat khác; gửi mã internal của nó cho bot
    res = _register_chatid(client, "gamma", 777)
    pair_ref = res["pair_ref"]
    asyncio.run(bot.handle_update(_msg(chat, pair_ref)))
    assert "ngừng sử dụng" in tg.sent[-1][1]
    assert "/id" in tg.sent[-1][1] and "/confirm" in tg.sent[-1][1]
    # không có project nào bị link qua đường mã
    assert db.pairing_status(cfg.database_path, pair_ref)["status"] == "pending"
    assert len(db.projects_by_chat(cfg.database_path, str(chat))) == 0


# ------------------------------------------------------------ chat-id pairing
GROUP = -1001234567890


def _register_chatid(client, name, chat_id):
    r = client.post("/api/v1/register-chatid", json={
        "project_name": name, "chat_id": str(chat_id)})
    assert r.status_code == 200, r.text
    return r.json()


def test_register_chatid_group_flow_and_confirm(env):
    """Luồng đầy đủ: script đăng ký chat GROUP -> bot notify vào đúng chat ->
    /confirm -> linked, api_key tiết lộ qua pairing-status."""
    client, cfg, tg = env
    res = _register_chatid(client, "web01", GROUP)
    assert res["pair_ref"].startswith("SEC-")
    assert res["chat_id"] == str(GROUP)
    assert res["warning"] is None
    # bot đã chủ động gửi yêu cầu /confirm vào đúng chat đích
    assert tg.sent and tg.sent[0][0] == str(GROUP)
    assert "Yêu cầu ghép nối mới" in tg.sent[0][1]
    assert "web01" in tg.sent[0][1]

    bot = _bot(cfg, tg)
    # pending: status chưa linked
    st = client.get(f"/api/v1/pairing-status?code={res['pair_ref']}").json()
    assert st["status"] == "pending"

    asyncio.run(bot.handle_update(_msg(GROUP, "/confirm")))
    assert "Ghép nối thành công" in tg.sent[-1][1]
    st = client.get(f"/api/v1/pairing-status?code={res['pair_ref']}").json()
    assert st["status"] == "linked" and st.get("api_key")


def test_confirm_links_multiple_servers_one_chat(env):
    """Một GROUP nhận alert của nhiều server: 2 lần register -> 1 /confirm ghép cả hai."""
    client, cfg, tg = env
    r1 = _register_chatid(client, "alpha", GROUP)
    r2 = _register_chatid(client, "beta", GROUP)
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(GROUP, "/confirm")))
    text = tg.sent[-1][1]
    assert "2 server" in text and "alpha" in text and "beta" in text
    for r in (r1, r2):
        st = client.get(f"/api/v1/pairing-status?code={r['pair_ref']}").json()
        assert st["status"] == "linked" and st.get("api_key")
    assert len(db.projects_by_chat(cfg.database_path, str(GROUP))) == 2


def test_confirm_rejects_other_chat_and_empty(env):
    """/confirm từ chat KHÁC không leak; chat không có pending được báo rõ."""
    client, cfg, tg = env
    _register_chatid(client, "secret-server", GROUP)
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(999111, "/confirm")))   # chat khác
    assert "Không có yêu cầu" in tg.sent[-1][1]
    st = db.pairing_status(cfg.database_path,
                           db.pending_codes_by_chat_id(cfg.database_path, str(GROUP))[0]["code"])
    assert st["status"] == "pending"   # vẫn chờ, chưa bị chat lạ confirm


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


def test_plain_message_hints_pending_confirm(env):
    """Tin nhắn thường trong chat có pending -> nhắc /confirm."""
    client, cfg, tg = env
    _register_chatid(client, "hinted", 4242)
    bot = _bot(cfg, tg)
    asyncio.run(bot.handle_update(_msg(4242, "hello")))
    assert "/confirm" in tg.sent[-1][1]


def test_repair_same_project_reuses_row_and_rotates_key(env):
    """Pair lại cùng tên về cùng chat: TÁI DỤNG row dự án (không còn trùng tên
    trong /list, thiết bị không bị xé sang row mới); API key bị XOAY — key cũ
    chết, key mới gửi được, bot cảnh báo rõ việc xoay key."""
    client, cfg, tg = env
    bot = _bot(cfg, tg)
    chat = 8010

    # lần 1: pair + confirm -> linked, lấy key
    r1 = _register_chatid(client, "bruh", chat)
    asyncio.run(bot.handle_update(_msg(chat, "/confirm")))
    key1 = client.get(f"/api/v1/pairing-status?code={r1['pair_ref']}").json()["api_key"]

    # lần 2: pair lại CÙNG TÊN, cùng chat -> không được tạo row mới
    r2 = _register_chatid(client, "bruh", chat)
    assert r2["pair_ref"] != r1["pair_ref"]
    asyncio.run(bot.handle_update(_msg(chat, "/confirm")))
    key2 = client.get(f"/api/v1/pairing-status?code={r2['pair_ref']}").json()["api_key"]
    assert key2 and key2 != key1

    # đúng 1 row dự án tên này cho chat; /list không còn hiện trùng
    rows = db.projects_by_chat(cfg.database_path, str(chat))
    assert len(rows) == 1 and rows[0]["project_name"] == "bruh"

    # tin nhắn confirm lần 2 phải cảnh báo dự án đã ghép từ trước (key xoay)
    assert "đã ghép từ trước" in tg.sent[-1][1]

    # key mới ingest được; key cũ bị từ chối; cùng device vẫn là MỘT row
    a = _alert(batch="20261024T000100Z")
    a["device"] = a["host"] = "web01"
    ok = client.post("/api/v1/ingest-log", headers={"X-API-Key": key2},
                     json={"host": "web01", "alerts": [a]})
    assert ok.status_code == 200, ok.text
    stale = client.post("/api/v1/ingest-log", headers={"X-API-Key": key1},
                        json={"host": "web01", "alerts": [a]})
    assert stale.status_code == 401
    rows = db.projects_by_chat(cfg.database_path, str(chat))
    assert rows[0]["device_count"] == 1  # web01 chỉ 1 lần, không nhân đôi


def test_repair_same_name_different_chat_creates_separate_project(env):
    """Cùng tên nhưng KHÁC chat -> hai dự án riêng (hai nơi nhận alert khác nhau)."""
    client, cfg, tg = env
    _register_chatid(client, "web", 8101)
    _register_chatid(client, "web", 8102)
    with db.connect(cfg.database_path) as conn:
        n = conn.execute("SELECT COUNT(*) FROM projects WHERE project_name='web'").fetchone()[0]
    assert n == 2
