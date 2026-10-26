"""Telegram: client gửi tin + bot polling xử lý mã pairing + format alert."""
import asyncio
import html
import logging
import re
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
    "CRITICAL": "🚨", "HIGH": "⚠️", "MEDIUM": "🟡", "MODERATE": "🟡",
    "LOW": "ℹ️", "INFO": "ℹ️",
}
_SEV_RANK = {"CRITICAL": 5, "HIGH": 4, "MEDIUM": 3, "MODERATE": 3, "LOW": 2, "INFO": 1}

# Alert headline: exactly two messages.
#   "Server bị chiếm quyền (RCE)" — any hit from an exploitation-success rule
#   (T3: webshell dropped, backdoor, host exec, fpm child shell, reverse shell).
#   "Server đang bị khai thác php2shell" — everything else, i.e. any batch with
#   more than 2 distinct rules (T1 pre-exploit probes / T2 in-progress signals).
# CRITICAL = the server IS compromised, not "is being attacked". A rule belongs
# here only when its own evidence proves code execution already happened or a
# payload is already sitting on disk / in a session file. Anything that is still
# just a probe stays out, however loud it is.
RCE_RULES = frozenset({
    "P2S-020",  # webroot file written/changed        -> shell landed
    "P2S-021",  # host process exec (auditd)           -> command ran
    "P2S-022",  # auto_prepend_file injected           -> persistent backdoor
    "P2S-024",  # php-fpm spawned shell child          -> command ran
    "P2S-025",  # reverse shell / post-exploitation    -> channel open
    "P2S-056",  # webshell pattern inside webroot      -> shell on disk
    "P2S-057",  # LFI tra 2xx + tham so nhan absolute path -> file da doc duoc
})
# Deliberately NOT here: P2S-050 / P2S-051 / P2S-054. Those fire on every LFI
# *attempt* (a request URI naming a session file or a php:// wrapper). They are
# the attack in progress, not proof it worked — including them would paint every
# noisy batch CRITICAL and bury the one batch where a shell really landed.
#
# P2S-057 là ranh giới: cùng một URI, 404 là "đang thử", 2xx là "đã đọc được".
# Rule này chỉ fire khi server thật sự trả nội dung file, nên nó là bằng chứng
# đọc file thành công — cùng hạng với shell đã lên đĩa, không phải dò quét.


def _split_ids(raw: Any) -> set[str]:
    """Split a rule_id field into individual ids.

    The monitor de-duplicates events: one raw log line that satisfies several
    rules carries them merged as "P2S-050,P2S-051". Treating that as a single
    string silently broke RCE detection (a merged "P2S-050,P2S-051" never
    matched the RCE set), so always split on the comma.
    """
    out: set[str] = set()
    for part in str(raw or "").split(","):
        part = part.strip()
        if part:
            out.add(part)
    return out


def _alert_rule_ids(alert: dict) -> set[str]:
    """Every rule_id present in the alert (evidence[] preferred, else counters)."""
    ids: set[str] = set()
    for h in alert.get("evidence") or []:
        if isinstance(h, dict) and h.get("rule_id"):
            ids |= _split_ids(h["rule_id"])
    if not ids:  # payload without evidence[]: fall back to the rule counters
        for r in alert.get("rules") or []:
            if isinstance(r, dict) and r.get("rule_id"):
                ids |= _split_ids(r["rule_id"])
        if alert.get("rule_id"):
            ids |= _split_ids(alert["rule_id"])
    return ids


def is_rce(alert: dict) -> bool:
    """True when the evidence proves the box is already compromised."""
    return bool(_alert_rule_ids(alert) & RCE_RULES)


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


def _headline(alert: dict) -> str:
    """What the alert says happened. Driven by the alert's own severity."""
    sev = _sev(alert)
    if sev == "CRITICAL" or is_rce(alert):
        return "Server bị chiếm quyền (RCE)"
    if sev == "INFO":
        return "Dấu hiệu dò quét php2shell"
    return "Server đang bị khai thác php2shell"
def format_alert(project_name: str, alert: dict, tz: ZoneInfo) -> str:
    """One batch alert -> one 5-line Telegram message.

    🛡 Central Security Alert - dd/mm/yyyy - hh:mm
    <emoji> <SEVERITY> · <what happened> · <n> events
    📦 Dự án: <project>
    <emoji> User: <user> - Hostname: <hostname>
    🖥 IP LAN: <lan ip>

    Full evidence (every raw hit with file:line) stays on the server
    (`GET /api/v1/alerts/<id>`) and in the evidence mirror.
    """
    esc = html.escape
    sev = _sev(alert)
    emoji = _SEV_EMOJI[sev]

    when = (_parse_ts(alert.get("ts_utc") or alert.get("ts") or alert.get("window_end"))
            or datetime.now(tz)).astimezone(tz)

    hits = alert.get("evidence") or []
    total = int(alert.get("hits") or len(hits))
    what = esc(_headline(alert))
    freq = f"{total} events"

    # "User" is the OS account the monitor runs as — the account that would own
    # any dropped shell. "Hostname" is what the machine calls itself. Both come
    # from the device envelope, so a renamed box or a service account is visible
    # straight from the alert.
    user = str(alert.get("user") or "").strip()[:64] or "không rõ"
    hostname = str(alert.get("hostname") or alert.get("host") or alert.get("device") or "?")[:64]
    lan_ip = str(alert.get("lan_ip") or "").strip()[:64] or "không rõ"

    return "\n".join([
        f"🛡 <b>Central Security Alert</b> - {when:%d/%m/%Y} - {when:%H:%M}",
        f"{emoji} <b>{esc(sev)}</b> · {what} · {freq}",
        f"📦 Dự án: <b>{esc(project_name[:64])}</b>",
        f"{emoji} User: <b>{esc(user)}</b> - Hostname: <b>{esc(hostname)}</b>",
        f"🖥 IP LAN: <b>{esc(lan_ip)}</b>",
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
    """Polling bot: quản lý server theo CHAT ID (chat riêng hoặc group).

    Luồng chat-id: /id lấy Chat ID -> script pair nhập Chat ID -> ghép nối
    TỰ ĐỘNG (không /confirm — triển khai số lượng lớn không spam). Một chat
    ghép được NHIỀU server; /list xem tất cả; /unlink ngắt một dự án.
    """

    # Menu lệnh (nút ≡ / gõ "/"). Tên: lowercase a-z0-9_, tối đa 32 ký tự.
    BOT_COMMANDS = [
        ("start", "Bắt đầu"),
        ("id", "Lấy Chat ID của chat này"),
        ("list", "Dự án & số thiết bị"),
        ("unlink", "Ngắt một dự án khỏi chat này"),
        ("help", "Trợ giúp"),
    ]
    # /start — đúng một câu, không kèm menu/hướng dẫn.
    START_TEXT = (
        "👋 Central Alert Bot — cảnh báo an ninh tấn công khai thác lỗ hổng "
        "php2Shell từ các server của bạn ngay trên Telegram."
    )
    # /help — ngắn gọn: danh sách lệnh + 1 dòng ghép nối.
    HELP_TEXT = (
        "🤖 <b>Central Alert Bot — Trợ giúp</b>\n"
        "• <code>/id</code> — lấy Chat ID của chat này\n"
        "• <code>/list</code> — dự án &amp; số thiết bị\n"
        "• <code>/unlink &lt;tên&gt;</code> — ngắt một dự án\n"
        "• <code>/help</code> — trợ giúp \n\n"
    )
    # /list khi chat chưa ghép dự án nào — không kèm hướng dẫn.
    LIST_EMPTY_TEXT = "📭 Chưa có dự án nào được ghép với chat này."
    BOT_DESCRIPTION = (
        "🛡 Central Alert Bot — nhận cảnh báo an ninh (php2shell-monitor) từ các"
        " server của bạn ngay trên Telegram.\n\n"
        "Ghép nối: /id lấy Chat ID → nhập vào script pair trên server — tự động"
        " ghép ngay, không cần xác nhận. Chat riêng hoặc group đều được; /list"
        " xem tất cả, /unlink để ngắt."
    )
    BOT_SHORT_DESCRIPTION = ("Cảnh báo an ninh server → Telegram."
                             " /id lấy Chat ID rồi chạy pair trên server.")

    def __init__(self, cfg: Config, tg: TelegramClient, db_path: str) -> None:
        self.cfg = cfg
        self.tg = tg
        self.db_path = db_path
        self.guard = AttemptGuard(cfg.bot_attempts_limit, cfg.bot_attempts_window_sec,
                                  cfg.bot_mute_sec)
        self._me: str = ""

    async def _api(self, method: str, **kwargs) -> dict:
        r = await self.tg._http.post(TG_API.format(token=self.cfg.bot_token, method=method),
                                     **kwargs)
        r.raise_for_status()
        return r.json()

    async def start(self) -> None:
        me = await self._api("getMe")
        self._me = me["result"].get("username", "")
        self.tg.bot_username = self._me  # routes dùng để trả bot handle cho agent
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
        if CODE_RE.search(text):
            await self.tg.send_message(
                chat_id,
                "⌛ Mã <code>SEC-&lt;UUID&gt;</code> đã ngừng sử dụng.\n"
                "Ghép nối bây giờ qua Chat ID: <code>/id</code> để lấy Chat ID →"
                " nhập vào script <code>pair</code> trên server — ghép nối tự"
                " động, không cần xác nhận gì thêm.",
            )
        elif cmd == "start":
            await self._cmd_help(chat_id, welcome=True)
        elif cmd == "help":
            await self._cmd_help(chat_id)
        elif cmd == "id":
            await self._cmd_id(chat_id, msg)
        elif cmd == "confirm":
            await self._cmd_confirm(chat_id, msg)
        elif cmd == "unlink":
            await self._cmd_unlink(chat_id, msg)
        elif cmd in ("list", "ids", "servers"):
            await self._cmd_list(chat_id)
        else:
            await self._cmd_help(chat_id)

    async def _cmd_id(self, chat_id: str, msg: dict) -> None:
        """In Chat ID để user copy vào script pair (chat riêng hoặc group)."""
        chat = msg.get("chat") or {}
        kind = "nhóm" if chat.get("type") in ("group", "supergroup") else "riêng tư"
        await self.tg.send_message(
            chat_id,
            f"🆔 <b>Chat ID: <code>{html.escape(chat_id)}</code></b>\n"
            f"📎 Loại: {kind}\n"
            + ("⚠️ Trong nhóm, bot cần được thêm làm <b>thành viên</b> để gửi"
               " cảnh báo vào đây." if kind == "nhóm" else ""),
        )

    async def _cmd_confirm(self, chat_id: str, msg: dict) -> None:
        """Đồng ý mọi yêu cầu ghép nối đang chờ của CHÍNH chat này."""
        who = str((msg.get("from") or {}).get("first_name") or "ai đó")
        n = len(db.projects_by_chat(self.db_path, chat_id))
        await self.tg.send_message(
            chat_id,
            "ℹ️ <b>Ghép nối giờ đã TỰ ĐỘNG — không cần /confirm nữa.</b>\n"
            "Chạy <code>pair</code> trên server với Chat ID của chat này là ghép"
            " xong ngay (server tự nhận API key).\n\n"
            f"📎 Chat này đang quản lý <b>{n} dự án</b> — <code>/list</code> để xem,"
            " <code>/unlink &lt;tên dự án&gt;</code> để ngắt một dự án.",
        )
        log.info("/confirm trong chat=%s (bởi %s) — ghép nối đã tự động", chat_id, who)

    async def _cmd_unlink(self, chat_id: str, msg: dict) -> None:
        """/unlink <tên dự án> — ngắt dự án khỏi chat: alert dừng gửi, lịch sử giữ."""
        who = str((msg.get("from") or {}).get("first_name") or "ai đó")
        parts = (msg.get("text") or "").split(maxsplit=1)
        name = parts[1].strip() if len(parts) > 1 else ""
        if not name:
            rows = db.projects_by_chat(self.db_path, chat_id)
            if not rows:
                await self.tg.send_message(
                    chat_id,
                    "Chat này chưa ghép dự án nào nên không có gì để ngắt.\n"
                    "Muốn bắt đầu: <code>/id</code> lấy Chat ID → chạy <code>pair</code>"
                    " trên server.",
                )
                return
            names = " · ".join(f"<code>/unlink {html.escape(r['project_name'])}</code>"
                               for r in rows)
            await self.tg.send_message(
                chat_id,
                "Cách dùng: <code>/unlink &lt;tên dự án&gt;</code>\n"
                f"Các dự án đang ghép với chat này: {names}",
            )
            return
        res = db.unlink_project(self.db_path, name, chat_id)
        if res is None:
            await self.tg.send_message(
                chat_id,
                f"❌ Không tìm thấy dự án <b>{html.escape(name)}</b> đang ghép với"
                " chat này (xem <code>/list</code>; tên phải viết đúng).",
            )
            return
        log.info("unlink: project=%s chat=%s (bởi %s)", name, chat_id, who)
        await self.tg.send_message(
            chat_id,
            f"🚫 <b>Đã ngắt dự án {html.escape(name)}</b>\n"
            "Alert từ dự án này sẽ KHÔNG còn gửi vào chat (lịch sử alert vẫn"
            " được lưu trên server trung tâm).\n"
            "Muốn ghép lại: chạy <code>pair</code> trên server của dự án.",
        )

    # ------------------------------------------------------------- lệnh

    async def _cmd_help(self, chat_id: str, welcome: bool = False) -> None:
        # /start: đúng một dòng giới thiệu, không kèm hướng dẫn.
        if welcome:
            await self.tg.send_message(chat_id, self.START_TEXT)
            return
        await self.tg.send_message(chat_id, self.HELP_TEXT)

    async def _cmd_list(self, chat_id: str) -> None:
        """Dự án đang quản lý + số thiết bị từng dự án. Không kèm hướng dẫn.

        Nghiệp vụ: một dự án khả dụng luôn có >= 1 thiết bị; dự án 0 thiết bị
        được đánh dấu "chưa khả dụng" thay vì ẩn đi.
        """
        rows = db.projects_by_chat(self.db_path, chat_id)
        if not rows:
            await self.tg.send_message(chat_id, self.LIST_EMPTY_TEXT)
            return

        counts = [int(r["device_count"]) for r in rows]
        active = sum(1 for c in counts if c)
        lines = [
            "🗂 <b>Dự án đang quản lý</b>",
            f"📦 Dự án: <b>{len(rows)}</b> (khả dụng <b>{active}</b>)"
            f" · Thiết bị: <b>{sum(counts)}</b>",
            "",
        ]
        for i, (r, n_dev) in enumerate(zip(rows, counts), 1):
            lines.append(f"{i}. <b>{html.escape(r['project_name'])}</b>")
            lines.append(f"    🖥 Số thiết bị: <b>{n_dev}</b>"
                         + ("" if n_dev else " — chưa khả dụng"))
        await self.tg.send_message(chat_id, "\n".join(lines))
