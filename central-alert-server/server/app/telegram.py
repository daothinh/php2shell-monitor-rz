"""Telegram: client gửi tin + bot polling xử lý mã pairing + format alert."""
import asyncio
import html
import logging
import re
import time
from datetime import datetime, timezone
from typing import Any, Optional
from zoneinfo import ZoneInfo

import httpx

from . import db
from .config import Config
from .security import AttemptGuard, gen_api_key, sha256_hex

log = logging.getLogger("alert-server.telegram")

TG_API = "https://api.telegram.org/bot{token}/{method}"
CODE_RE = re.compile(
    r"\bSEC-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b"
)

_SEV_EMOJI = {
    "CRITICAL": "🚨", "HIGH": "⚠️", "MEDIUM": "🟡", "LOW": "ℹ️", "INFO": "ℹ️",
}
_SEV_RANK = {"CRITICAL": 5, "HIGH": 4, "MEDIUM": 3, "LOW": 2, "INFO": 1}

# Alert headline: exactly two messages.
#   "Server bị chiếm quyền (RCE)" — any hit from an exploitation-success rule
#   (T3: webshell dropped, backdoor, host exec, fpm child shell, reverse shell).
#   "Server đang bị khai thác php2shell" — everything else, i.e. any batch with
#   more than 2 distinct rules (T1 pre-exploit probes / T2 in-progress signals).
RCE_RULES = frozenset({
    "P2S-020",  # webroot file written/changed
    "P2S-021",  # host process exec (auditd)
    "P2S-022",  # auto_prepend_file injected (backdoor)
    "P2S-024",  # php-fpm spawned shell child
    "P2S-025",  # reverse shell / post-exploitation
})


def _alert_rule_ids(alert: dict) -> set[str]:
    """Every rule_id present in the alert (evidence[] preferred, else counters)."""
    ids: set[str] = set()
    for h in alert.get("evidence") or []:
        if isinstance(h, dict) and h.get("rule_id"):
            ids.add(str(h["rule_id"]))
    if not ids:  # payload without evidence[]: fall back to the rule counters
        for r in alert.get("rules") or []:
            if isinstance(r, dict) and r.get("rule_id"):
                ids.add(str(r["rule_id"]))
        if alert.get("rule_id"):
            ids.add(str(alert["rule_id"]))
    return ids


def _headline(alert: dict) -> str:
    """One of the two allowed messages for the alert headline."""
    ids = _alert_rule_ids(alert)
    if ids & RCE_RULES:
        return "Server bị chiếm quyền (RCE)"
    return "Server đang bị khai thác php2shell"
DEFAULT_WINDOW_MIN = 5   # monitor BATCH_INTERVAL


def _sev(a: dict) -> str:
    s = str(a.get("severity") or "").upper()
    return s if s in _SEV_EMOJI else "INFO"


def _parse_ts(ts_raw: Any) -> Optional[datetime]:
    s = str(ts_raw or "")
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        try:  # định dạng CLF-ish 2026-10-23 14:02:11
            dt = datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
        return dt.replace(tzinfo=timezone.utc)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _window_span(alert: dict) -> str:
    """Batch window as a short duration: '5 phút' / '<1 phút' (5 min default)."""
    start = _parse_ts(alert.get("window_start"))
    end = _parse_ts(alert.get("window_end"))
    if not (start and end and end > start):
        return f"{DEFAULT_WINDOW_MIN} phút"
    secs = int((end - start).total_seconds())
    if secs < 60:
        return "<1 phút"
    return f"{max(1, round(secs / 60))} phút"


def format_alert(project_name: str, alert: dict, tz: ZoneInfo) -> str:
    """One batch alert -> one 4-line Telegram message.

    🛡 Central Security Alert - DD/MM/YYYY
    <emoji> SEVERITY · <what happened> · <hits>/<window>
    📦 Dự án: <project>
    🖥 <hostname> / <LAN IP>

    Full evidence (every raw hit with file:line) stays on the server
    (`GET /api/v1/alerts/<id>`) and in the evidence mirror.
    """
    esc = html.escape
    sev = _sev(alert)

    when = (_parse_ts(alert.get("ts_utc") or alert.get("ts") or alert.get("window_end"))
            or datetime.now(tz)).astimezone(tz)

    hits = alert.get("evidence") or []
    total = int(alert.get("hits") or len(hits))
    what = f"<b>{esc(_headline(alert))}</b>"
    # _window_span có thể trả "<1 phút" — escape kẻo Telegram parse <1...> thành HTML tag
    freq = f"{total} hit / {esc(_window_span(alert))}"

    host = str(alert.get("host") or alert.get("device") or "?")[:64]
    lan_ip = str(alert.get("lan_ip") or "").strip()[:64]
    where = f"🖥 <b>{esc(host)}</b>" + (f" / {esc(lan_ip)}" if lan_ip else "")

    return "\n".join([
        f"🛡 <b>Central Security Alert</b> - {when:%d/%m/%Y}",
        f"{_SEV_EMOJI[sev]} <b>{esc(sev)}</b> · {what} · {freq}",
        f"📦 Dự án: <b>{esc(project_name[:64])}</b>",
        where,
    ])


class TelegramClient:
    """Gửi tin nhắn qua Bot API + giữ nhịp ≤1 tin/giây/chat."""

    def __init__(self, token: str) -> None:
        self.token = token
        self._http = httpx.AsyncClient(timeout=20)
        self._last_sent: dict[str, float] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    async def aclose(self) -> None:
        await self._http.aclose()

    async def send_message(self, chat_id: str, text: str) -> tuple[bool, str]:
        """Trả (thành công?, lỗi). Xử lý 429 (retry_after) tự động."""
        lock = self._locks.setdefault(chat_id, asyncio.Lock())
        async with lock:
            elapsed = asyncio.get_event_loop().time() - self._last_sent.get(chat_id, 0.0)
            if elapsed < 1.05:
                await asyncio.sleep(1.05 - elapsed)
            for attempt in (1, 2):
                try:
                    r = await self._http.post(
                        TG_API.format(token=self.token, method="sendMessage"),
                        data={"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                              "disable_web_page_preview": "true"},
                    )
                except httpx.HTTPError as e:
                    return False, f"network: {e}"
                if r.status_code == 429:
                    retry = float(r.json().get("parameters", {}).get("retry_after", 3))
                    await asyncio.sleep(min(retry, 15) + 0.5)
                    continue
                if r.status_code == 200:
                    self._last_sent[chat_id] = asyncio.get_event_loop().time()
                    return True, ""
                body = r.text[:200]
                if attempt == 2:
                    return False, f"telegram http {r.status_code}: {body}"
        return False, "telegram retries exhausted"


class PairingBot:
    """Polling bot: điều phối lệnh quản lý server + nhận mã SEC-<UUID> ghép nối.

    Một chat Telegram (một người) có thể ghép NHIỀU server: mỗi lần thêm server
    chạy lệnh /add_new_id rồi gửi mã SEC-... của server đó; /list xem tất cả.
    """

    AWAIT_TTL_SEC = 600  # /add_new_id hiệu lực 10 phút — khớp TTL mã pairing

    # Menu lệnh (nút ≡ / gõ "/"). Tên: lowercase a-z0-9_, tối đa 32 ký tự.
    BOT_COMMANDS = [
        ("start", "Bắt đầu & xem tổng quan"),
        ("add_new_id", "Ghép nối thêm server mới"),
        ("list", "Danh sách server/dự án đã ghép"),
        ("help", "Trợ giúp đầy đủ"),
    ]
    BOT_DESCRIPTION = (
        "🛡 Central Alert Bot — nhận cảnh báo an ninh (php2shell-monitor) từ các"
        " server của bạn ngay trên Telegram.\n\n"
        "Một chat quản lý được nhiều server: chạy /add_new_id rồi gửi mã SEC-<UUID>"
        " in trên terminal server để ghép nối. /list xem tất cả."
    )
    BOT_SHORT_DESCRIPTION = ("Cảnh báo an ninh server → Telegram. "
                             "/add_new_id để ghép nối server mới.")

    def __init__(self, cfg: Config, tg: TelegramClient, db_path: str) -> None:
        self.cfg = cfg
        self.tg = tg
        self.db_path = db_path
        self.guard = AttemptGuard(cfg.bot_attempts_limit, cfg.bot_attempts_window_sec,
                                  cfg.bot_mute_sec)
        self._me: str = ""
        self._awaiting: dict[str, float] = {}  # chat_id -> thời điểm /add_new_id

    async def _api(self, method: str, **kwargs) -> dict:
        r = await self.tg._http.post(TG_API.format(token=self.cfg.bot_token, method=method),
                                     **kwargs)
        r.raise_for_status()
        return r.json()

    async def start(self) -> None:
        me = await self._api("getMe")
        self._me = me["result"].get("username", "")
        log.info("bot @%s polling started", self._me)
        # Đăng ký menu lệnh (nút ≡ / gõ "/"): idempotent, lỗi không chặn polling
        for method, payload in (
            ("setMyCommands", {"commands": [
                {"command": c, "description": d} for c, d in self.BOT_COMMANDS]}),
            ("setMyDescription", {"description": self.BOT_DESCRIPTION}),
            ("setMyShortDescription", {"short_description": self.BOT_SHORT_DESCRIPTION}),
        ):
            try:
                await self._api(method, json=payload)
            except Exception:  # noqa: BLE001
                log.warning("bot %s thất bại (menu/mô tả không cập nhật)", method)

    async def run(self) -> None:
        offset = 0
        while True:
            try:
                if not self._me:
                    await self.start()
                data = await self.tg._http.get(
                    TG_API.format(token=self.cfg.bot_token, method="getUpdates"),
                    params={"offset": offset, "timeout": 25},
                    timeout=30,
                )
                data.raise_for_status()
                for upd in data.json().get("result", []):
                    offset = max(offset, upd["update_id"] + 1)
                    try:
                        await self.handle_update(upd)
                    except Exception:  # noqa: BLE001 — không làm chết vòng polling
                        log.exception("xử lý update %s lỗi", upd.get("update_id"))
            except Exception:  # noqa: BLE001 — cả lỗi getMe/getUpdates: chờ rồi thử lại
                log.warning("polling/getMe lỗi (token sai hoặc mất mạng?), thử lại sau 10s")
                await asyncio.sleep(10)

    async def handle_update(self, upd: dict) -> None:
        msg = upd.get("message") or upd.get("edited_message") or {}
        chat_id = str((msg.get("chat") or {}).get("id") or "")
        text = str(msg.get("text") or "").strip()
        if not chat_id:
            return
        if self.guard.is_muted(chat_id):
            return

        # Lệnh (chuẩn hoá: bỏ '/', bỏ @botname, chữ thường)
        cmd = text.split()[0].lstrip("/").split("@")[0].lower() if text else ""
        m = CODE_RE.search(text)
        if m:
            await self._cmd_pair_code(chat_id, f"SEC-{m.group(1)}")
        elif cmd == "start":
            await self._cmd_help(chat_id, welcome=True)
        elif cmd == "help":
            await self._cmd_help(chat_id)
        elif cmd == "add_new_id":
            await self._cmd_add_new_id(chat_id)
        elif cmd in ("list", "ids", "servers"):
            await self._cmd_list(chat_id)
        elif self._awaiting_active(chat_id):
            await self.tg.send_message(
                chat_id,
                "⏳ Đang chờ mã ghép nối <code>SEC-&lt;UUID&gt;</code> của server mới "
                "(in trên terminal khi chạy lệnh <code>pair</code>).",
            )
        else:
            await self._cmd_help(chat_id)

    def _awaiting_active(self, chat_id: str) -> bool:
        """Chat đang trong phiên /add_new_id chưa hết hạn (TTL AWAIT_TTL_SEC)."""
        t0 = self._awaiting.get(chat_id)
        if t0 is None:
            return False
        if time.monotonic() - t0 > self.AWAIT_TTL_SEC:
            self._awaiting.pop(chat_id, None)
            return False
        return True

    # ------------------------------------------------------------- lệnh

    async def _cmd_help(self, chat_id: str, welcome: bool = False) -> None:
        n = len(db.projects_by_chat(self.db_path, chat_id))
        head = ("👋 <b>Chào mừng!</b> Đây là <b>Central Alert Bot</b> — nhận cảnh báo"
                " an ninh từ các server của bạn ngay trên Telegram."
                if welcome else "🤖 <b>Central Alert Bot — Trợ giúp</b>")
        await self.tg.send_message(
            chat_id,
            head + "\n"
            "Một chat có thể quản lý <b>nhiều server</b> — mỗi server ghép một mã riêng.\n\n"
            "📋 <b>Lệnh</b> — nhấn <b>≡</b> cạnh ô nhập hoặc gõ <code>/</code> để mở menu:\n"
            "• <code>/add_new_id</code> — ➕ ghép nối một server mới\n"
            "• <code>/list</code> — 🗂 các server/dự án đã ghép với chat này\n"
            "• <code>/help</code> — 📖 trợ giúp này\n\n"
            "🔌 <b>Ghép nối server mới (3 bước)</b>\n"
            "1️⃣ Trên server, chạy <code>sudo p2s-agent.sh pair --server &lt;url&gt;</code>\n"
            "2️⃣ Terminal in mã <code>SEC-&lt;UUID&gt;</code> — gửi mã về chat này\n"
            "3️⃣ Bot xác nhận ✅ — mọi cảnh báo của server sẽ về đúng chat này\n\n"
            + (f"📎 Bạn đang quản lý <b>{n} dự án</b>. Dùng <code>/list</code> để xem chi tiết."
               if n else "📎 Chưa có server nào được ghép với chat này — bắt đầu với"
                         " <code>/add_new_id</code>."),
        )

    async def _cmd_add_new_id(self, chat_id: str) -> None:
        self._awaiting[chat_id] = time.monotonic()
        n = len(db.projects_by_chat(self.db_path, chat_id))
        await self.tg.send_message(
            chat_id,
            "➕ <b>Thêm server mới</b>\n"
            "1️⃣ Trên server mới, chạy: <code>sudo p2s-agent.sh pair --server &lt;url&gt;</code>\n"
            "2️⃣ Terminal in mã <code>SEC-&lt;UUID&gt;</code> — gửi mã về đây\n"
            f"⏳ Tôi đang chờ mã của bạn (trong {self.AWAIT_TTL_SEC // 60} phút).\n\n"
            + (f"📎 Bạn đang quản lý {n} dự án — server mới sẽ thêm vào cùng chat này."
               if n else ""),
        )

    async def _cmd_list(self, chat_id: str) -> None:
        rows = db.projects_by_chat(self.db_path, chat_id)
        if not rows:
            await self.tg.send_message(
                chat_id,
                "📭 Chưa có server/dự án nào được ghép với chat này.\n"
                "Dùng <code>/add_new_id</code> để bắt đầu ghép nối server đầu tiên.",
            )
            return
        lines = [f"🗂 <b>Server/dự án của bạn ({len(rows)})</b>"]
        for i, r in enumerate(rows, 1):
            when = (r["linked_at"] or "")[:10]
            n_dev = r["device_count"]
            last = (r["last_alert_at"] or "")[:16].replace("T", " ")
            status = "✅" if r["status"] == "linked" else "⏸"
            lines.append(
                f"{i}. {status} <b>{html.escape(r['project_name'])}</b>"
                f" — {n_dev} thiết bị, ghép {when}"
                + (f", alert gần nhất {last} (UTC)" if last else ", chưa có alert")
            )
        await self.tg.send_message(chat_id, "\n".join(lines))

    async def _cmd_pair_code(self, chat_id: str, code: str) -> None:
        self._awaiting.pop(chat_id, None)  # hết trạng thái chờ, dù thành/bại
        try:
            res = db.complete_pairing(self.db_path, code, chat_id, gen_api_key, sha256_hex)
        except db.PairingError as e:
            self.guard.record_fail(chat_id)
            await self.tg.send_message(chat_id, f"❌ Ghép nối thất bại: {html.escape(e.reason)}")
            return
        self.guard.record_success(chat_id)
        n = len(db.projects_by_chat(self.db_path, chat_id))
        await self.tg.send_message(
            chat_id,
            "✅ <b>Ghép nối thành công!</b>\n"
            f"📦 Dự án: <b>{html.escape(res['project_name'])}</b>\n"
            f"📎 Chat này hiện quản lý <b>{n} dự án</b>.\n"
            "Server dự án sẽ tự nhận API key — mọi cảnh báo sẽ được gửi về đúng chat này.\n"
            "➕ Thêm server khác: <code>/add_new_id</code> · 🗂 Xem tất cả: <code>/list</code>",
        )
        log.info("pairing hoàn tất: project=%s chat=%s (chat có %d dự án)",
                 res["project_id"], chat_id, n)
