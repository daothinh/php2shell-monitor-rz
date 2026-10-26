"""API endpoints: pairing, ingest, ops (alerts/devices/stats/search), admin, health."""
import html
import gzip
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


class RegisterChatIdBody(BaseModel):
    project_name: str = Field(min_length=1, max_length=64)
    chat_id: str = Field(min_length=1, max_length=20)
    device: Optional[str] = Field(default=None, max_length=64)  # nhãn key (hostname)


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


def _key_rejection(cfg: Config, api_key: str) -> HTTPException:
    """401 có phân loại lý do: dự án bị ngắt (/unlink) khác key không hợp lệ.

    Agent phía máy đọc detail.code (project_disabled) để biết phải chạy lại
    lệnh deploy thay vì retry mù — /unlink trên bot không có kênh báo ngược
    về thiết bị nên đây là cách máy tự phát hiện.
    """
    owner = db.api_key_owner(cfg.database_path, sha256_hex(api_key))
    if owner is not None:
        return HTTPException(401, detail={
            "code": "project_disabled",
            "message": "Dự án đã bị ngắt (/unlink trên bot) — chạy lại lệnh"
                       " deploy trên máy để ghép nối lại",
        })
    return HTTPException(401, "API key không hợp lệ hoặc dự án chưa ghép nối")


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
        raise _key_rejection(cfg, api_key)
    return int(project["id"])


# ------------------------------------------------------------- pairing
# (Nhánh feature/chatid-pairing: chỉ còn luồng Chat ID — register-pairing mã
#  SEC-<UUID> đã bị bỏ, mỗi feature một kiểu pairing riêng.)

@router.post("/register-chatid")
async def register_chatid(body: RegisterChatIdBody, request: Request):
    """Luồng pairing theo CHAT ID Telegram (private user hoặc group đều được).

    Ghép nối TỰ ĐỘNG — không cần /confirm (triển khai số lượng lớn: 1000 thiết bị
    không ai ngồi confirm từng máy). Script hỏi user chat ID (lấy từ /id của
    bot) rồi gọi endpoint này; server cấp API key NGAY (mỗi lần gọi cấp THÊM
    một key, các key cũ vẫn sống). Bot chỉ nhắn 1 tin duy nhất vào chat khi dự
    án lần đầu được ghép (kèm lệnh /unlink để tự vệ); re-pair thêm máy thì im
    lặng."""
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
    label = (body.device or "").strip()[:64]
    res = db.auto_link_code(cfg.database_path, pair_ref, gen_api_key, sha256_hex, label)
    log.info("chat-id auto-pairing: project=%s chat=%s newly_linked=%s",
             project_id, chat_id, res["newly_linked"])

    # Chỉ dự án MỚI được thông báo vào chat (1 tin/khách); thêm máy im lặng.
    warning = ""
    tg = request.app.state.telegram
    if res["newly_linked"] and tg is not None and hasattr(tg, "send_message"):
        sent, err = await tg.send_message(
            chat_id,
            "✅ <b>Đã tự động ghép nối</b>\n"
            f"📦 Dự án <b>{html.escape(body.project_name)}</b> vừa ghép với chat này"
            " — mọi cảnh báo của dự án sẽ về đây (không cần làm gì thêm).\n"
            "🚫 Không phải do bạn? Nhắn <code>/unlink "
            f"{html.escape(body.project_name)}</code> để ngắt ngay.",
        )
        if not sent:
            warning = (f"bot chưa nhắn được vào chat {chat_id} (chưa START): {err} —"
                       " dự án VẪN đã ghép và key đã cấp; hãy mở bot (hoặc thêm bot"
                       " vào group) để nhận được alert")
    return {
        "pair_ref": pair_ref,
        "chat_id": chat_id,
        "bot": (f"@{getattr(tg, 'bot_username', '')}"
                if getattr(tg, "bot_username", "") else None),
        "auto_linked": True,
        "expires_in": cfg.pairing_ttl_sec,
        "expires_at": db.iso(db.utcnow() + timedelta(seconds=cfg.pairing_ttl_sec)),
        "instruction": "Đã ghép nối tự động — script sẽ nhận API key ngay",
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


@router.get("/whoami")
def whoami(request: Request, x_api_key: str = Header(default=""),
           authorization: str = Header(default="")):
    """Health-check ghép nối cho agent: key này còn sống không, thuộc dự án nào.

    200 = pairing còn hiệu lực (agent giữ nguyên conf). 401 kèm
    detail.code=project_disabled = bị /unlink trên bot → agent/phía deploy
    phải ghép nối lại. Nhẹ và không tác dụng phụ — dùng cho guard idempotent
    của script, thay vì chỉ tin file conf local.
    """
    cfg = _cfg(request)
    api_key = x_api_key or (authorization[7:] if authorization.lower().startswith("bearer ") else "")
    if not api_key:
        raise HTTPException(401, "Thiếu API key (header X-API-Key hoặc Authorization: Bearer)")
    key_hash = sha256_hex(api_key)
    project = db.project_by_api_key_hash(cfg.database_path, key_hash)
    if project is not None:
        return {
            "status": "linked",
            "project_id": int(project["id"]),
            "project_name": project["project_name"],
            "chat_id": project["telegram_chat_id"],
        }
    raise _key_rejection(cfg, api_key)


# ------------------------------------------------------- ingest evidence

@router.post("/ingest-evidence")
async def ingest_evidence(
    request: Request,
    x_api_key: str = Header(default=""),
    authorization: str = Header(default=""),
    x_batch_id: str = Header(default=""),
    x_hostname: str = Header(default=""),
    x_lan_ip: str = Header(default=""),
    x_user: str = Header(default=""),
):
    """Receive the gzipped JSONL evidence for one batch, verbatim.

    Kept separate from /ingest-log so the alert line stays small: a 300k-hit
    batch is a 148 MB JSON line inline, which no shell pipeline can carry, but
    only ~2 MB gzipped. The body is streamed to the mirror as-is — the server
    does not re-encode or re-order it, so what the device captured is what the
    operator reads.
    """
    cfg = _cfg(request)
    api_key = x_api_key or (authorization[7:] if authorization.lower().startswith("bearer ") else "")
    project = _auth_project(request, api_key)
    batch = db.slug(x_batch_id or "")
    if not batch:
        raise HTTPException(400, "Thiếu X-Batch-Id")

    label = evidence.device_label({
        "lan_ip": x_lan_ip, "hostname": x_hostname,
    })
    path = evidence.evidence_path(cfg, project["project_name"], label, batch)
    path.parent.mkdir(parents=True, exist_ok=True)

    raw = await request.body()
    if not raw:
        raise HTTPException(400, "Body rỗng")
    try:
        data = gzip.decompress(raw)
    except OSError:
        raise HTTPException(400, "Body không phải gzip hợp lệ")

    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_bytes(data)
    tmp.replace(path)
    lines = data.count(b"\n")
    log.info("evidence %s/%s: %d dòng, %d bytes (gz %d)",
             project["project_name"], batch, lines, len(data), len(raw))
    return {"ok": True, "batch_id": batch, "events": lines,
            "bytes": len(data), "file": str(path)}


# ------------------------------------------------------------- ingest

class IngestBody(BaseModel):
    host: Optional[str] = Field(default=None, max_length=128)
    device: Optional[str] = Field(default=None, max_length=64)
    lan_ip: Optional[str] = Field(default=None, max_length=64)
    user: Optional[str] = Field(default=None, max_length=64)
    os: Optional[str] = Field(default=None, max_length=80)     # PRETTY_NAME, vd Ubuntu 24.04.1 LTS
    env: Optional[str] = Field(default=None, max_length=32)    # Docker Container / Container / Host
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
        raise _key_rejection(cfg, api_key)
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
                                   body.user or "", body.os or "", body.env or "")
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
        res = db.auto_link_code(cfg.database_path, body.code,
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
