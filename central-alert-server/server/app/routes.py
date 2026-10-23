"""API endpoints: pairing, ingest-log, admin, health."""
import logging
import re
from datetime import timedelta
from typing import Any, Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

from . import db
from .config import Config
from .security import RateLimiter, gen_api_key, gen_pairing_code, sha256_hex
from .telegram import TelegramClient, chunk_messages, format_alert

log = logging.getLogger("alert-server.api")

router = APIRouter(prefix="/api/v1")

_limiter = RateLimiter()
_NAME_RE = re.compile(r"^[A-Za-z0-9À-ỹ._@\- ]{1,64}$")


UUID_CODE_RE = r"^SEC-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"


class RegisterBody(BaseModel):
    project_name: str = Field(min_length=1, max_length=64)


class AdminLinkBody(BaseModel):
    code: str = Field(pattern=UUID_CODE_RE, to_upper=True)
    chat_id: str = Field(min_length=1, max_length=32)


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    return (fwd.split(",")[0].strip() if fwd else None) or (request.client.host if request.client else "?")


def _cfg(request: Request) -> Config:
    return request.app.state.cfg


def _tz(request: Request) -> ZoneInfo:
    return request.app.state.tz


# ------------------------------------------------------------- pairing

@router.post("/register-pairing")
def register_pairing(body: RegisterBody, request: Request):
    """Client script xin mã ghép nối (in ra terminal cho user gửi tới bot)."""
    cfg = _cfg(request)
    if not _NAME_RE.match(body.project_name):
        raise HTTPException(422, "project_name 1-64 ký tự, chỉ chữ/số/._-@ và khoảng trắng")
    ip = _client_ip(request)
    ok, retry = _limiter.allow(f"reg:{ip}", cfg.register_rate_per_hour, 3600)
    if not ok:
        raise HTTPException(429, f"Quá nhiều lượt đăng ký từ IP này; thử lại sau {retry}s")
    project_id = db.create_project(cfg.database_path, body.project_name)
    code = db.issue_pairing_code(cfg.database_path, project_id, cfg.pairing_ttl_sec,
                                 gen_pairing_code)
    log.info("pairing code phát hành: project=%s code=%s", project_id, code)
    return {
        "code": code,
        "expires_in": cfg.pairing_ttl_sec,
        "expires_at": db.iso(db.utcnow() + timedelta(seconds=cfg.pairing_ttl_sec)),
        "instruction": f"Gửi mã {code} cho bot Telegram để hoàn tất ghép nối",
    }


@router.get("/pairing-status")
def pairing_status(code: str, request: Request):
    """Client poll: pending | linked (kèm api_key, tiết lộ trong cửa sổ reveal)."""
    cfg = _cfg(request)
    code = code.strip().upper()
    if not re.match(UUID_CODE_RE, code):
        raise HTTPException(422, "code phải có dạng SEC-<UUID>")
    st = db.pairing_status(cfg.database_path, code)
    if st is None:
        raise HTTPException(404, "Mã không tồn tại")
    if st["status"] == "linked" and "api_key" in st:
        db.mark_revealed(cfg.database_path, code)
    return st


# ------------------------------------------------------------- ingest

class IngestBody(BaseModel):
    host: Optional[str] = Field(default=None, max_length=128)
    alerts: list[dict[str, Any]] = Field(min_length=1)


@router.post("/ingest-log")
async def ingest_log(
    body: IngestBody,
    request: Request,
    x_api_key: str = Header(default=""),
    authorization: str = Header(default=""),
):
    """Nhận alert từ client (X-API-Key hoặc Bearer), định dạng và bắn Telegram."""
    cfg = _cfg(request)
    api_key = x_api_key or (authorization[7:] if authorization.lower().startswith("bearer ") else "")
    if not api_key:
        raise HTTPException(401, "Thiếu API key (header X-API-Key hoặc Authorization: Bearer)")
    ok, retry = _limiter.allow(f"ingest:{sha256_hex(api_key)[:16]}",
                               cfg.ingest_rate_per_min, 60)
    if not ok:
        raise HTTPException(429, f"Quá nhanh; thử lại sau {retry}s")

    project = db.project_by_api_key_hash(cfg.database_path, sha256_hex(api_key))
    if project is None:
        raise HTTPException(401, "API key không hợp lệ hoặc dự án chưa ghép nối")
    chat_id = project["telegram_chat_id"]
    if not chat_id:
        raise HTTPException(409, "Dự án chưa có telegram_chat_id")

    alerts = body.alerts[: cfg.max_alerts_per_request]
    tz = _tz(request)
    header = "🛡 <b>Central Security Alert</b>"
    blocks = [format_alert(project["project_name"], a, tz, body.host or "") for a in alerts]
    messages = chunk_messages(header, blocks)

    tg: TelegramClient = request.app.state.telegram
    delivered, last_err = 0, ""
    for m in messages:
        sent, err = await tg.send_message(chat_id, m)
        if sent:
            delivered += 1
        else:
            last_err = err
            log.warning("gửi telegram thất bại project=%s: %s", project["id"], err)
    all_sent = delivered == len(messages)
    db.log_alerts(cfg.database_path, project["id"], alerts, all_sent)
    out: dict[str, Any] = {"accepted": len(alerts), "messages": len(messages), "delivered": delivered}
    if last_err:
        out["warning"] = f"alert đã nhận nhưng gửi Telegram lỗi: {last_err}"
    return out


# ------------------------------------------------------------- admin / ops

@router.post("/admin/link")
def admin_link(body: AdminLinkBody, request: Request, x_admin_token: str = Header(default="")):
    """Ghép nối thủ công (dev/ops) không qua Telegram. Chỉ bật khi có ALERT_ADMIN_TOKEN."""
    cfg = _cfg(request)
    if not cfg.admin_token:
        raise HTTPException(404, "không bật")
    if x_admin_token != cfg.admin_token:
        raise HTTPException(403, "admin token sai")
    try:
        res = db.complete_pairing(cfg.database_path, body.code, body.chat_id,
                                  gen_api_key, sha256_hex)
    except db.PairingError as e:
        raise HTTPException(409, e.reason) from e
    log.info("admin link: project=%s chat=%s", res["project_id"], body.chat_id)
    return {"status": "linked", "project_id": res["project_id"],
            "project_name": res["project_name"]}


@router.get("/healthz")
def healthz(request: Request):
    cfg = _cfg(request)
    return {
        "ok": True,
        "bot": "polling" if cfg.bot_polling else "disabled",
        "projects": db.count_projects(cfg.database_path),
        "time_utc": db.iso(),
    }
