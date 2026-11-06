"""API endpoints: pairing, ingest, ops (alerts/devices/stats/search), admin, health."""
import asyncio
import html
import gzip
import json
import logging
import re
import secrets
from datetime import timedelta
from typing import Any, Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

from . import db, dedup, evidence, preview, telegram
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
    monitor_version: Optional[str] = Field(default=None, max_length=32)


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
    # device_label để phân biệt "cùng máy đổi chat" với "hai khách trùng tên"
    project_id = db.create_project(cfg.database_path, body.project_name,
                                   telegram_chat_id=chat_id,
                                   device_label=(body.device or ""))
    pair_ref = db.issue_pairing_code(cfg.database_path, project_id, cfg.pairing_ttl_sec,
                                     gen_pairing_code)
    label = (body.device or "").strip()[:64]
    res = db.auto_link_code(cfg.database_path, pair_ref, gen_api_key, sha256_hex, label)
    log.info("chat-id auto-pairing: project=%s chat=%s newly_linked=%s",
             project_id, chat_id, res["newly_linked"])

    # Tin GHÉP NỐI THÀNH CÔNG — gửi ở MỌI lần cài, không chỉ dự án mới.
    #
    # Đây là minh chứng Telegram hoạt động, thay cho alert TEST-001 đã bỏ:
    #   - alert TEST-001 đi qua đúng khung "CENTRAL SECURITY ALERT" nên người
    #     trực ca không phân biệt được với sự cố thật, và bấm lại là thêm tin;
    #   - tin ghép nối nói đúng bản chất: "máy này vừa được cài và đã nối được",
    #     không có khung cảnh báo an ninh, không nằm trong bảng alerts.
    #
    # Vì sao KHÔNG chỉ gửi khi newly_linked: phần lớn khách đã triển khai từ
    # trước, nên lần cài trên máy mới (hoặc cài lại) là re-pair — im lặng thì
    # operator không có cách nào biết tuyến agent→server→Telegram đã thông.
    # "Đã cài xong mà chat không có tin" chính là tín hiệu hỏng cần thấy.
    warning = ""
    tg = request.app.state.telegram
    dev_label = (body.device or "").strip()
    if tg is not None and hasattr(tg, "send_message"):
        # Tin ngắn, đúng 4 dòng thông tin — không lời dẫn, không hướng dẫn.
        # Bản monitor hiển thị ngay trong tin: khi khách có nhiều máy, đây là
        # cách duy nhất biết máy nào đang chạy bản nào mà không phải SSH vào.
        # Cài mới và cài đè bản update đều đi qua đúng endpoint này nên cả hai
        # trường hợp đều thấy version hiện tại.
        ver = (body.monitor_version or "").strip()[:32] or "không rõ"
        # Khung cố định 3 dòng thông tin: dự án · thiết bị · version. Thiếu giá
        # trị thì ghi "không rõ" chứ không bỏ dòng — tin giữ đúng một hình dạng
        # để người đọc quét mắt theo cùng một vị trí mỗi lần.
        lines = [
            "✅ <b>GHÉP NỐI THÀNH CÔNG</b>",
            "",
            f"📦 <b>Dự án:</b> <code>{html.escape(body.project_name)}</code>",
            f"🏷 <b>Thiết bị:</b> <code>{html.escape(dev_label or 'không rõ')}</code>",
            f"🛠 <b>php2Shell-monitor:</b> <code>{html.escape(ver)}</code>",
        ]
        sent, err = await tg.send_message(chat_id, "\n".join(lines))
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

    # Raw vừa lên -> gửi bù ngay các alert của dự án đang chờ vì thiếu bằng chứng.
    # Đây là mắt xích giữ bất biến "alert phải có raw": alert tới trước evidence
    # không bị mất, chỉ bị hoãn tới đúng lúc có raw.
    flushed = 0
    try:
        flushed = await preview.flush_awaiting(cfg, cfg.database_path,
                                               request.app.state.telegram,
                                               _tz(request))
    except Exception:  # noqa: BLE001 — không được làm hỏng việc nhận evidence
        log.exception("gửi bù alert sau khi nhận evidence lỗi")
    if flushed:
        log.info("gửi bù %d alert đang chờ raw (sau evidence %s/%s)",
                 flushed, project["project_name"], batch)

    return {"ok": True, "batch_id": batch, "events": lines,
            "bytes": len(data), "file": str(path), "flushed_alerts": flushed}


# ------------------------------------------------------------- ingest

class IngestBody(BaseModel):
    host: Optional[str] = Field(default=None, max_length=128)
    device: Optional[str] = Field(default=None, max_length=64)
    lan_ip: Optional[str] = Field(default=None, max_length=64)
    user: Optional[str] = Field(default=None, max_length=64)
    os: Optional[str] = Field(default=None, max_length=80)     # PRETTY_NAME, vd Ubuntu 24.04.1 LTS
    env: Optional[str] = Field(default=None, max_length=32)    # Docker Container / Container / Host
    monitor_version: Optional[str] = Field(default=None, max_length=32)
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


# Thiết bị nào liên tiếp không có evidence mirror (monitor quá cũ, hoặc agent
# không upload) thì thôi chờ: mỗi alert 2s × 50 alert/request sẽ làm nghẽn ingest.
_NO_EVIDENCE_STREAK: dict[str, int] = {}
_NO_EVIDENCE_GIVE_UP = 3


async def _attach_preview_from_evidence(cfg: Config, project_name: str,
                                        alert: dict, device_name: str) -> bool:
    """Dựng preview[] từ evidence mirror của đúng batch, chờ file lên tới server.

    Trả True khi gắn được. Idempotent và rẻ: file có ngay (đa số trường hợp, vì
    agent upload evidence ngay sau alert) thì không sleep lần nào.
    """
    key = f"{project_name}/{device_name}"
    wait = float(getattr(cfg, "preview_wait_sec", 0) or 0)
    if _NO_EVIDENCE_STREAK.get(key, 0) >= _NO_EVIDENCE_GIVE_UP:
        wait = 0.0
    deadline = asyncio.get_event_loop().time() + max(wait, 0.0)
    while True:
        if preview.attach(cfg, project_name, alert):
            _NO_EVIDENCE_STREAK.pop(key, None)
            return True
        if asyncio.get_event_loop().time() >= deadline:
            _NO_EVIDENCE_STREAK[key] = _NO_EVIDENCE_STREAK.get(key, 0) + 1
            return False
        await asyncio.sleep(0.2)


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
    stored = duplicated = deferred = 0
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

        # 1b. Alert KHÔNG mang preview[] (monitor <= 1.4.2, hoặc
        # ALERT_PREVIEW_MAX=0): dựng lại từ evidence mirror. Agent upload evidence
        # ngay sau alert nên chờ tối đa preview_wait_sec để file kịp lên — nếu
        # không, mọi alert từ máy chưa nâng cấp vẫn hiện "Event logs 0 nhóm".
        from_evidence = False
        if not alert.get("preview"):
            from_evidence = await _attach_preview_from_evidence(
                cfg, project["project_name"], alert, device_name)
            # preview[] là raw line thật -> lưu luôn thành hit để /alerts/{id} và
            # /search thấy được (normalize() đã chạy trước khi preview có mặt).
            if from_evidence and not alert.get("evidence"):
                alert["evidence"] = evidence.hits_from_preview(alert)
            # Đường dẫn evidence thật trên server: alert tới trước file nên
            # write_evidence() ở trên không ghi được gì — thiếu dòng này thì DB
            # trỏ vào chuỗi rỗng và không ai biết raw của batch nằm ở đâu.
            if from_evidence and not ev_file:
                ev_file = str(alert.get("_evidence_mirror") or "")
            # Không có file mirror (agent chưa upload) nhưng đã dựng được raw từ
            # payload: ghi ra mirror để lần tra cứu sau có nguồn, và để
            # evidence_file không rỗng.
            if not ev_file:
                ev_file = evidence.write_evidence(cfg, project["project_name"], alert)
            if not from_evidence:
                log.warning("alert không có raw event (thiếu preview[] và chưa có"
                            " evidence mirror) project=%s device=%s batch=%s hits=%s"
                            " — nâng cấp monitor lên >= 1.4.4",
                            project["id"], device_name, alert.get("batch_id"),
                            alert.get("hits"))

        # 1b-bis. Con số hiển thị trên Telegram: số event THẬT server nhận được,
        # không phải tổng bộ đếm rule của monitor. Monitor đếm hits theo rule nên
        # một dòng log khớp 2 rule bị tính 2, và agent gửi lại payload sau khi mất
        # mạng làm số đó phồng thêm — người trực ca đọc một con số không có thật.
        # Ưu tiên đếm trên file evidence mirror (đủ mọi raw của batch); chưa có
        # file thì đếm trên evidence[] đã dedup; không có gì thì để trống và
        # format_alert rơi về preview_meta/hits.
        if alert.get("_event_total") is None:
            ev_path = ev_file or str(alert.get("_evidence_mirror") or "")
            counted = preview.count_events(ev_path) if ev_path else 0
            if counted:
                alert["_event_total"] = counted

        # 1c. CHỐNG TRÙNG TRƯỚC KHI GỬI.
        # Agent gửi lại cùng payload khi mất mạng (spool retry) là chuyện bình
        # thường. Nếu chỉ dựa vào INSERT OR IGNORE ở bước 3 thì alert đã tồn tại
        # vẫn bị gửi Telegram lần nữa -> sysadmin nhận 2-3 tin cho cùng một sự
        # kiện. Hỏi DB trước: batch này đã lưu thì không gửi, không ghi lại.
        prev_id = db.alert_id_for_device_batch(cfg.database_path, device_id,
                                               str(alert.get("batch_id") or ""))
        if prev_id is not None:
            duplicated += 1
            log.info("bỏ qua alert trùng (đã gửi trước đó): project=%s device=%s"
                     " batch=%s alert_id=%s", project["id"], device_name,
                     alert.get("batch_id"), prev_id)
            results.append({"batch_id": alert.get("batch_id"),
                            "status": "duplicate", "alert_id": prev_id})
            continue

        # 2. notify — CHỈ KHI CÓ RAW.
        # Nghiệp vụ: alert Telegram bắt buộc kèm raw event. Một tin chỉ có
        # "N events" mà không có dòng log nào là thông tin không hành động được:
        # sysadmin không biết máy nào / file nào / request nào, và lần sau sẽ bỏ
        # qua cảnh báo. Không có raw thì KHÔNG gửi; alert vẫn được lưu và sẽ gửi
        # bù ngay khi evidence lên (xem /ingest-evidence).
        sent = False
        suppressed = False
        sent_groups: list[dict] = []
        if not telegram.has_raw(alert):
            deferred += 1
            log.warning("HOÃN gửi Telegram: alert chưa có raw event "
                        "(project=%s device=%s batch=%s hits=%s) — sẽ gửi bù khi"
                        " evidence lên tới server",
                        project["id"], device_name, alert.get("batch_id"),
                        alert.get("hits"))
        else:
            # 2b. CHẶN ALERT LẶP: event đã báo cho thiết bị này trong cửa sổ dedup
            # thì không hiện lại. Monitor <= 1.4.2 không dedup ở nguồn nên một
            # webshell nằm yên trên đĩa sinh tin giống hệt nhau mỗi 5 phút (đo
            # trên lab: 48 tin cho đúng một shell) — người trực ca sẽ tắt kênh.
            all_groups = list(alert.get("preview") or [])
            dropped = dedup.apply(cfg, cfg.database_path, device_id, alert)
            if dropped and not (alert.get("preview") or []):
                # Toàn bộ event của batch đã báo trước: không có gì mới để nói.
                # Alert vẫn được lưu để tra cứu, nhưng KHÔNG gửi tin rỗng và
                # KHÔNG vào hàng đợi gửi bù (nếu vào, cleanup sẽ gửi lại đúng
                # cái vừa bị chặn).
                suppressed = True
                log.info("bỏ gửi: toàn bộ %d nhóm event đã báo trước"
                         " (device=%s batch=%s)", dropped, device_id,
                         alert.get("batch_id"))
            else:
                if dropped:
                    log.info("gửi %d nhóm mới, bỏ %d nhóm đã báo trước"
                             " (device=%s batch=%s)",
                             len(alert.get("preview") or []), dropped,
                             device_id, alert.get("batch_id"))
                text = format_alert(project["project_name"], alert, tz)
                sent, err = await tg.send_message(chat_id, text)
                if sent:
                    delivered += 1
                    messages += 1
                    sent_groups = list(alert.get("preview") or [])
                else:
                    # Telegram lỗi (mất mạng, token sai, 429 kéo dài): alert
                    # KHÔNG được coi là đã gửi. Trước đây messages=1 ở đây nên
                    # alert rơi khỏi hàng đợi và mất vĩnh viễn — sự kiện RCE xảy
                    # ra mà không ai nhận được tin, không có cách nào gửi lại.
                    deferred += 1
                    last_err = err
                    log.warning("gửi telegram thất bại, xếp hàng gửi bù:"
                                " project=%s device=%s batch=%s: %s",
                                project["id"], device_name,
                                alert.get("batch_id"), err)

        # 3. persist (idempotent on (device, batch_id): agent retries are safe)
        # messages = 1 chỉ khi THẬT SỰ đã gửi. Hoãn vì thiếu raw thì messages=0
        # để hàng đợi gửi bù (/ingest-evidence, cleanup loop) nhặt lại.
        alert_id = db.store_alert(cfg.database_path, project["id"], device_id, alert,
                                  ev_file, sent, 1 if sent else 0)
        if alert_id is None:
            duplicated += 1
            results.append({"batch_id": alert.get("batch_id"), "status": "duplicate"})
        else:
            stored += 1
            if suppressed:
                # messages=2 = cố ý không gửi. Khác hẳn messages=0 (đang chờ gửi
                # bù): nếu để 0, cleanup loop sẽ gửi lại đúng tin vừa bị chặn.
                db.mark_alert_suppressed(cfg.database_path, alert_id)
            if sent_groups:
                # Chỉ ghi nhận event ĐÃ THẬT SỰ tới chat: ghi trước thì một lần
                # gửi lỗi sẽ vĩnh viễn chặn event đó ở các batch sau.
                dedup.remember(cfg.database_path, device_id, alert_id, sent_groups)
            results.append({
                "batch_id": alert.get("batch_id"),
                "status": "suppressed" if suppressed else "stored",
                "alert_id": alert_id,
                "severity": alert["severity"],
                "hits": alert["hits"],
                "duplicate_events": int(alert.get("_duplicate_events") or 0),
                "evidence_file": ev_file,
            })

    out: dict[str, Any] = {
        "accepted": stored,
        "duplicates": duplicated,
        "deferred": deferred,
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


@router.post("/alerts/{alert_id}/resend")
async def resend_alert(alert_id: int, request: Request,
                       x_admin_token: str = Header(default=""),
                       x_read_token: str = Header(default="")):
    """Gửi lại một alert đã lưu, dựng lại preview[] từ evidence mirror.

    Dùng cho sự cố đã xảy ra: tin nhắn cũ đã tới chat với khối Event logs rỗng
    (monitor <= 1.4.2), không sửa lại được. Endpoint đọc alert + file evidence
    trên server rồi bắn một tin vào đúng chat của dự án.

    Tin gửi lại giữ ĐÚNG khuôn alert thật: không nhãn, không chú thích, không
    lộ chi tiết triển khai. Cái duy nhất phân biệt nó với tin đầu là thời điểm
    Telegram gửi — giống hệt một alert bình thường khác giờ, đúng như người trực
    ca cần. Việc "tin này là bản gửi lại" chỉ ghi ở log server, không lên chat.

    Cần ALERT_ADMIN_TOKEN (hoặc read token): đây là thao tác ghi ra Telegram.
    """
    cfg = _cfg(request)
    tok = x_admin_token or x_read_token
    expected = cfg.admin_token or cfg.read_token
    if not expected:
        raise HTTPException(404, "không bật (thiếu ALERT_ADMIN_TOKEN)")
    if not secrets.compare_digest(tok, expected):
        raise HTTPException(403, "token sai")

    detail = db.alert_detail(cfg.database_path, alert_id)
    if detail is None:
        raise HTTPException(404, "alert không tồn tại")
    chat_id = db.chat_id_of_project(cfg.database_path, int(detail["project_id"]))
    if not chat_id:
        raise HTTPException(409, "dự án chưa có telegram_chat_id")

    alert = dict(detail)
    alert["rules"] = detail.get("rules") or []
    # Envelope đã lưu cùng alert (bản vá sau sự cố): tin dựng lại phải nói đúng
    # máy nào, không được hiện "Hostname: ?" / "IP LAN: không rõ".
    for k in ("lan_ip", "hostname", "user", "os", "env"):
        if detail.get(k):
            alert[k] = detail[k]
    # containers: cột JSON -> list, để tin gửi lại vẫn có dòng 🐳 Container
    try:
        _c = json.loads(detail.get("containers") or "[]")
        alert["containers"] = [str(x) for x in _c] if isinstance(_c, list) else []
    except (TypeError, ValueError):
        alert["containers"] = []
    alert["hits"] = detail.get("hit_count") or alert.get("hits")

    # preview: ưu tiên file evidence trên mirror (đầy đủ nhất, mới nhất), không
    # còn file thì dựng từ alert_hits đã lưu trong DB.
    limit = int(cfg.preview_max or 8)
    path = preview.find_evidence(cfg, detail["project_name"],
                                 str(detail.get("batch_id") or ""),
                                 str(detail.get("device_name") or ""))
    if path is not None:
        groups, total, _cut = preview.groups_from_jsonl(path, limit)
        if groups:
            alert["preview"] = groups
            alert["preview_meta"] = f"{total}|{len(groups)}"
            alert["_preview_source"] = "evidence"
    if not alert.get("preview"):
        groups, total = preview.groups_from_records(detail.get("evidence") or [], limit)
        if groups:
            alert["preview"] = groups
            alert["preview_meta"] = f"{total}|{len(groups)}"
            alert["_preview_source"] = "alert_hits"

    # Cùng bất biến với đường ingest: không có raw thì không gửi. Ở đây trả lỗi
    # rõ ràng thay vì hoãn, vì đây là thao tác thủ công — người gọi cần biết
    # ngay là alert này không có bằng chứng để dựng lại.
    if not telegram.has_raw(alert):
        raise HTTPException(409, {
            "code": "no_raw_evidence",
            "message": "Alert không có raw event để dựng lại (evidence mirror đã"
                       " bị xoá và alert_hits rỗng) — không gửi tin thiếu bằng chứng",
        })

    # Cùng bất biến số liệu như đường ingest: đếm event thật, dedup.
    counted = preview.count_events(path) if path is not None else 0
    if counted:
        alert["_event_total"] = counted

    # Resend là thao tác của operator nên KHÔNG chặn theo dedup (họ chủ động gửi
    # lại để đối chiếu khung tin). Nhưng phải ghi nhận các event vừa gửi, nếu
    # không lần resend sau lại thấy chúng là "mới" và dedup mất tác dụng.
    _resend_groups = list(alert.get("preview") or [])

    text = format_alert(detail["project_name"], alert, _tz(request))
    tg: TelegramClient = request.app.state.telegram
    sent, err = await tg.send_message(chat_id, text)
    if not sent:
        raise HTTPException(502, f"gửi Telegram lỗi: {err}")
    if _resend_groups:
        dedup.remember(cfg.database_path,
                       int(detail.get("device_id") or 0), alert_id, _resend_groups)
    log.info("resend alert_id=%s project=%s chat=%s (có preview=%s)",
             alert_id, detail["project_name"], chat_id, bool(alert.get("preview")))
    return {"ok": True, "alert_id": alert_id, "chat_id": chat_id,
            "preview_groups": len(alert.get("preview") or []),
            "preview_source": alert.get("_preview_source")
                               or ("alert_hits" if alert.get("preview") else "none")}


@router.get("/healthz")
def healthz(request: Request):
    cfg = _cfg(request)
    return {
        "ok": True,
        "bot": "polling" if cfg.bot_polling else "disabled",
        "projects": db.count_projects(cfg.database_path),
        "time_utc": db.iso(),
    }
