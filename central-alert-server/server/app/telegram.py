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
    freq = f"{total} hit / {_window_span(alert)}"

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
    """Polling bot: nhận mã SEC-XXXX từ user, hoàn tất ghép nối, trả lời kết quả."""

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
        log.info("bot @%s polling started", self._me)

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
        m = CODE_RE.search(text)
        if not m:
            await self.tg.send_message(
                chat_id,
                "🤖 <b>Central Alert Bot</b>\n"
                "Gửi mã ghép nối (dạng <code>SEC-&lt;UUID&gt;</code>, ví dụ "
                "<code>SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301</code>) hiển thị trên"
                " terminal server dự án để nhận cảnh báo về chat này.",
            )
            return
        code = f"SEC-{m.group(1)}"
        try:
            res = db.complete_pairing(self.db_path, code, chat_id, gen_api_key, sha256_hex)
        except db.PairingError as e:
            self.guard.record_fail(chat_id)
            await self.tg.send_message(chat_id, f"❌ Ghép nối thất bại: {html.escape(e.reason)}")
            return
        self.guard.record_success(chat_id)
        await self.tg.send_message(
            chat_id,
            "✅ <b>Ghép nối thành công!</b>\n"
            f"📦 Dự án: <b>{html.escape(res['project_name'])}</b>\n"
            "Server dự án sẽ tự nhận API key — mọi cảnh báo sẽ được gửi về đúng chat này.",
        )
        log.info("pairing hoàn tất: project=%s chat=%s", res["project_id"], chat_id)
