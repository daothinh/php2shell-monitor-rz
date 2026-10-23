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
MSG_LIMIT = 3900  # giới hạn Telegram 4096, chừa buffer an toàn
CODE_RE = re.compile(r"\bSEC-(\d{4})\b", re.IGNORECASE)

_SEV_EMOJI = {
    "CRITICAL": "🚨", "HIGH": "⚠️", "MEDIUM": "🟡", "LOW": "ℹ️", "INFO": "ℹ️",
}


def _sev(a: dict) -> str:
    s = str(a.get("severity") or "").upper()
    return s if s in _SEV_EMOJI else "INFO"


def _fmt_ts(ts_raw: Any, tz: ZoneInfo) -> str:
    s = str(ts_raw or "")
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        try:  # định dạng CLF-ish 2026-10-23 14:02:11
            dt = datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(tz).strftime("%d/%m %H:%M:%S")


def format_alert(project_name: str, alert: dict, tz: ZoneInfo, host_default: str = "") -> str:
    """Một alert -> khối HTML ngắn gọn cho Telegram."""
    esc = html.escape
    sev = _sev(alert)
    emoji = _SEV_EMOJI[sev]
    rule = esc(str(alert.get("rule_id") or "LOG"))
    tier = str(alert.get("tier") or "").strip().upper()
    tier_tag = f" <code>[{esc(tier)}]</code>" if tier else ""

    host = esc(str(alert.get("host") or host_default or "?")[:64])
    lines = [f"{emoji} <b>{esc(sev)} · {rule}</b>{tier_tag} — <b>{host}</b>"]

    uri = str(alert.get("uri") or "").strip()
    if uri:
        lines.append(f"🔗 <code>{esc(uri[:160])}</code>")

    # IP: hỗ trợ cả src_ip trực tiếp lẫn src_ip_candidates của php2shell-monitor
    ip = str(alert.get("src_ip") or "").strip()
    if not ip:
        cands = alert.get("src_ip_candidates") or []
        if isinstance(cands, list) and cands:
            first = cands[0]
            if isinstance(first, dict):
                ip = f"{first.get('ip', '?')} (ứng viên, {first.get('score', '?')} hit)"
            else:
                ip = str(first)
    if ip:
        lines.append(f"👤 IP: <code>{esc(ip[:100])}</code>")

    msg = str(alert.get("message") or alert.get("notes") or "").strip()
    if not msg:
        evid = alert.get("evidence") or []
        if isinstance(evid, list) and evid and isinstance(evid[0], dict):
            msg = str(evid[0].get("msg") or "")
    if msg:
        lines.append(f"📝 {esc(msg[:300])}")

    ts = _fmt_ts(alert.get("ts_utc") or alert.get("ts") or alert.get("timestamp"), tz)
    if ts:
        lines.append(f"🕒 {ts} ({tz.key.split('/')[-1].replace('_', ' ')})")

    lines.append(f"📦 Dự án: <b>{esc(project_name[:64])}</b>")
    return "\n".join(lines)


def chunk_messages(header: str, blocks: list[str], footer: str = "") -> list[str]:
    """Gộp các khối alert thành tin nhắn ≤ MSG_LIMIT ký tự (tin mới mở lại bằng header)."""
    out: list[str] = []
    cur = header
    has_block = False
    for b in blocks:
        sep = "\n\n" if has_block else ""
        if has_block and len(cur) + len(sep) + len(b) + len(footer) > MSG_LIMIT:
            out.append(cur + footer)
            cur = header + b
        else:
            cur += sep + b
        has_block = True
    out.append(cur + footer)
    return out


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
                "Gửi mã ghép nối (dạng <code>SEC-1234</code>) hiển thị trên terminal server dự án"
                " để nhận cảnh báo về chat này.",
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
