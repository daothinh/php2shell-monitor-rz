"""API endpoints: pairing, ingest, ops (alerts/devices/stats/search), admin, health."""
import html
import logging
import re
import secrets
from datetime import timedelta
from typing import Any, Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

from . import db, evidence
from .config import Config
from .security import RateLimiter, gen_api_key, gen_pairing_code, sha256_hex
from .telegram import TelegramClient, format_alert

log = logging.getLogger("alert-server.api")

router = APIRouter(prefix="/api/v1")

_limiter = RateLimiter()
_NAME_RE = re.compile(r"^[A-Za-z0-9À-ỹ._@\- ]{1,64}$")


UUID_CODE_RE = r"^SEC-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"


class RegisterBody(BaseModel):
    project_name: str = Field(min_length=1, max_length=64)


class RegisterChatIdBody(BaseModel):
    project_name: str = Field(min_length=1, max_length=64)
    chat_id: str = Field(min_length=1, max_length=20)


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


def _read_scope(request: Request, x_api_key: str = Header(default=""),
                authorization: str = Header(default=""),
                x_admin_token: str = Header(default=""),
                x_read_token: str = Header(default="")) -> Optional[int]:
    """Xác thực endpoint đọc. Trả `project_id` được phép xem, `None` = mọi project.

    Thứ tự ưu tiên: admin token / read token (xem tất cả) → API key của project
    (chỉ thấy project mình). Không có credential hợp lệ → 401.
    """
    cfg = _cfg(request)
    if cfg.admin_token and x_admin_token and secrets.compare_digest(x_admin_token, cfg.admin_token):
        return None
    if cfg.read_token and x_read_token and secrets.compare_digest(x_read_token, cfg.read_token):
        return None
    api_key = x_api_key or (authorization[7:] if authorization.lower().startswith("bearer ") else "")
    if not api_key:
        raise HTTPException(401, "Thiếu credential đọc: X-API-Key, Authorization: Bearer, "
                                 "X-Read-Token hoặc X-Admin-Token")
    project = db.project_by_api_key_hash(cfg.database_path, sha256_hex(api_key))
    if project is None:
        raise HTTPException(401, "API key không hợp lệ hoặc dự án chưa ghép nối")
    return int(project["id"])


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


@router.post("/register-chatid")
async def register_chatid(body: RegisterChatIdBody, request: Request):
    """Luồng pairing theo CHAT ID Telegram (private user hoặc group đều được).

    Script chạy trên server dự án hỏi user nhập chat ID (lấy từ lệnh /id của
    bot) rồi gọi endpoint này. Server tạo project pending + pair_ref nội bộ,
    và bot gửi yêu cầu xác nhận vào đúng chat đó — ai đó trong chat nhắn
    /confirm trong TTL là ghép nối xong. User không phải gõ mã nào.
    """
    cfg = _cfg(request)
    if not _NAME_RE.match(body.project_name):
        raise HTTPException(422, "project_name 1-64 ký tự, chỉ chữ/số/._-@ và khoảng trắng")
    try:
        chat_id = db.norm_chat_id(body.chat_id)
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    ip = _client_ip(request)
    ok, retry = _limiter.allow(f"reg:{ip}", cfg.register_rate_per_hour, 3600)
    if not ok:
        raise HTTPException(429, f"Quá nhiều lượt đăng ký từ IP này; thử lại sau {retry}s")
    project_id = db.create_project(cfg.database_path, body.project_name,
                                   telegram_chat_id=chat_id)
    pair_ref = db.issue_pairing_code(cfg.database_path, project_id, cfg.pairing_ttl_sec,
                                     gen_pairing_code)
    log.info("chat-id pairing: project=%s chat=%s", project_id, chat_id)

    # Bot chủ động thông báo vào chat đích để /confirm tại chỗ
    # (duck-typing: TestClient thay bot bằng stub cùng giao diện send_message)
    warning = ""
    tg = request.app.state.telegram
    if tg is not None and hasattr(tg, "send_message"):
        sent, err = await tg.send_message(
            chat_id,
            "🔔 <b>Yêu cầu ghép nối mới</b>\n"
            f"📦 Server: <b>{html.escape(body.project_name)}</b> muốn gửi cảnh báo"
            " về chat này.\n"
            f"✅ Nhắn <code>/confirm</code> trong {cfg.pairing_ttl_sec // 60} phút"
            " để đồng ý (hoặc làm ngơ để huỷ).",
        )
        if not sent:
            warning = (f"chưa nhắn được bot vào chat {chat_id}: {err} — hãy mở bot"
                       " (hoặc thêm bot vào group) rồi nhắn /confirm ở đó")
    return {
        "pair_ref": pair_ref,
        "chat_id": chat_id,
        "expires_in": cfg.pairing_ttl_sec,
        "expires_at": db.iso(db.utcnow() + timedelta(seconds=cfg.pairing_ttl_sec)),
        "instruction": f"Nhắn /confirm trong chat {chat_id} để hoàn tất ghép nối",
        "warning": warning or None,
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
    device: Optional[str] = Field(default=None, max_length=64)
    lan_ip: Optional[str] = Field(default=None, max_length=64)
    user: Optional[str] = Field(default=None, max_length=64)
    alerts: list[dict[str, Any]] = Field(min_length=1)


def _auth_project(request: Request, api_key: str) -> Any:
    cfg = _cfg(request)
    if not api_key:
        raise HTTPException(401, "Thiếu API key (header X-API-Key hoặc Authorization: Bearer)")
    ok, retry = _limiter.allow(f"ingest:{sha256_hex(api_key)[:16]}",
                               cfg.ingest_rate_per_min, 60)
    if not ok:
        raise HTTPException(429, f"Quá nhanh; thử lại sau {retry}s")
    project = db.project_by_api_key_hash(cfg.database_path, sha256_hex(api_key))
    if project is None:
        raise HTTPException(401, "API key không hợp lệ hoặc dự án chưa ghép nối")
    return project


@router.post("/ingest-log")
async def ingest_log(
    body: IngestBody,
    request: Request,
    x_api_key: str = Header(default=""),
    authorization: str = Header(default=""),
):
    """Receive batch alerts from a device: store, mirror evidence, notify Telegram.

    Expected shape (php2shell-monitor): one alert per 5-minute batch, whose
    `evidence` array holds every raw hit line with file/line. Legacy single-hit
    payloads are accepted and normalized into the same shape.
    """
    cfg = _cfg(request)
    api_key = x_api_key or (authorization[7:] if authorization.lower().startswith("bearer ") else "")
    project = _auth_project(request, api_key)
    chat_id = project["telegram_chat_id"]
    if not chat_id:
        raise HTTPException(409, "Dự án chưa có telegram_chat_id")

    tz = _tz(request)
    tg: TelegramClient = request.app.state.telegram
    stored = duplicated = 0
    messages = delivered = 0
    last_err = ""
    results: list[dict[str, Any]] = []

    for raw_alert in body.alerts[: cfg.max_alerts_per_request]:
        alert = evidence.normalize(raw_alert, body.host or "", body.lan_ip or "",
                                   body.user or "")
        device_name = body.device or evidence.device_of(alert, body.host or "")
        device_id = db.upsert_device(cfg.database_path, project["id"], device_name)

        # 1. mirror the raw hits to disk first: never lose evidence to a DB error
        ev_file = evidence.write_evidence(cfg, project["project_name"], alert)

        # 2. notify: exactly one compact message per alert
        text = format_alert(project["project_name"], alert, tz)
        sent, err = await tg.send_message(chat_id, text)
        if sent:
            delivered += 1
        else:
            last_err = err
            log.warning("gửi telegram thất bại project=%s device=%s: %s",
                        project["id"], device_name, err)
        messages += 1

        # 3. persist (idempotent on (device, batch_id): agent retries are safe)
        alert_id = db.store_alert(cfg.database_path, project["id"], device_id, alert,
                                  ev_file, sent, 1)
        if alert_id is None:
            duplicated += 1
            results.append({"batch_id": alert.get("batch_id"), "status": "duplicate"})
        else:
            stored += 1
            results.append({
                "batch_id": alert.get("batch_id"),
                "status": "stored",
                "alert_id": alert_id,
                "severity": alert["severity"],
                "hits": alert["hits"],
                "evidence_file": ev_file,
            })

    out: dict[str, Any] = {
        "accepted": stored,
        "duplicates": duplicated,
        "messages": messages,
        "delivered": delivered,
        "alerts": results,
    }
    if last_err:
        out["warning"] = f"alert đã lưu nhưng gửi Telegram lỗi: {last_err}"
    return out


# ------------------------------------------------------------- ops / query

@router.get("/devices")
def list_devices(request: Request,
                 scope: Optional[int] = Depends(_read_scope),
                 project_id: Optional[int] = Query(default=None)):
    """Every monitored device with alert counters — the inventory view.

    API key chỉ thấy device của project mình; admin/read token thấy tất cả.
    """
    cfg = _cfg(request)
    if scope is not None:
        if project_id is not None and project_id != scope:
            raise HTTPException(403, "API key không có quyền xem project này")
        project_id = scope
    return {"devices": [dict(r) for r in db.stats(cfg.database_path, project_id)]}


@router.get("/alerts")
def list_alerts(
    request: Request,
    scope: Optional[int] = Depends(_read_scope),
    limit: int = Query(default=20, ge=1, le=200),
    project_id: Optional[int] = None,
    device_id: Optional[int] = None,
    severity: Optional[str] = None,
):
    cfg = _cfg(request)
    if scope is not None:
        if project_id is not None and project_id != scope:
            raise HTTPException(403, "API key không có quyền xem project này")
        project_id = scope
    rows = db.recent_alerts(cfg.database_path, limit, project_id, device_id, severity)
    return {"alerts": [dict(r) for r in rows]}


@router.get("/alerts/{alert_id}")
def get_alert(alert_id: int, request: Request,
              scope: Optional[int] = Depends(_read_scope)):
    """Full alert including every raw hit line (file + line + raw)."""
    cfg = _cfg(request)
    detail = db.alert_detail(cfg.database_path, alert_id, scope)
    if detail is None:
        raise HTTPException(404, "alert không tồn tại")
    return detail


@router.get("/search")
def search(request: Request, scope: Optional[int] = Depends(_read_scope),
           q: str = Query(min_length=2), limit: int = Query(default=100, ge=1, le=500)):
    """Free-text search across stored raw hit lines."""
    cfg = _cfg(request)
    return {"query": q,
            "hits": [dict(r) for r in db.search_hits(cfg.database_path, q, limit, scope)]}


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
