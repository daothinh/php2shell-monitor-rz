"""Cấu hình Central Alert Server — đọc từ biến môi trường / file .env."""
import os
from dataclasses import dataclass, field

try:  # pydantic-settings nếu có; không thì tự parse .env thủ công
    from pydantic_settings import BaseSettings  # noqa: F401

    _HAS_PYDANTIC_SETTINGS = True
except ImportError:
    _HAS_PYDANTIC_SETTINGS = False


def _load_dotenv(path: str = ".env") -> None:
    """Nạp .env đơn giản (KEY=VALUE) nếu file tồn tại, không ghi đè env sẵn có."""
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip("'\"")
            if key and key not in os.environ:
                os.environ[key] = val


@dataclass
class Config:
    bot_token: str = ""
    database_path: str = "data/alerts.db"
    evidence_root: str = "data/evidence"  # mirror of raw hits: <root>/<project>/IP-LAN_<ip>_<host>_<user>/
    retention_days: int = 90            # 0 = keep forever (alerts + evidence)
    pairing_ttl_sec: int = 600          # mã pairing sống 10 phút
    reveal_ttl_sec: int = 600           # api_key được lấy lại trong 10 phút sau lần đầu
    admin_token: str = ""               # bật endpoint /admin/link + đọc toàn bộ nếu khác rỗng
    read_token: str = ""                # token chỉ-đọc (dashboard/ops): xem mọi project
    bot_polling: bool = True
    max_alerts_per_request: int = 50
    ingest_rate_per_min: int = 120      # giới hạn request/phút theo api_key
    register_rate_per_hour: int = 30    # giới hạn đăng ký pairing/giờ theo IP
    bot_attempts_limit: int = 5         # số lần nhập sai mã tối đa trước khi khoá tạm
    bot_attempts_window_sec: int = 600
    bot_mute_sec: int = 600
    display_tz: str = "Asia/Ho_Chi_Minh"
    # Số nhóm event dựng lại từ evidence mirror khi alert KHÔNG mang preview[]
    # (monitor <= 1.4.2). 0 = tắt. Phải khớp ALERT_PREVIEW_MAX của monitor để
    # "… +N nhóm" trên tin nhắn không lệch giữa hai bản.
    preview_max: int = 8
    # Trần thời gian (giây) chờ file evidence của batch lên tới server trước khi
    # render tin: agent upload evidence NGAY SAU alert, nên đọc sớm quá sẽ trượt.
    preview_wait_sec: float = 2.0
    # Cửa sổ gửi bù: alert chưa gửi được (thiếu raw / Telegram lỗi) chỉ được gửi
    # bù trong khoảng này. Quá hạn thì giữ trong DB để tra cứu nhưng KHÔNG gửi —
    # update server không được phát lại cảnh báo cũ vào chat của khách.
    resend_window_sec: int = 3600
    # Cửa sổ chặn event lặp: event đã gửi Telegram trong khoảng này thì không
    # hiện lại. Lý do tồn tại: monitor <= 1.4.2 không dedup ở nguồn nên một
    # webshell nằm yên trên đĩa sinh tin giống hệt nhau mỗi 5 phút (đo trên lab:
    # 48 tin cho đúng một shell). 0 = tắt dedup.
    dedup_window_sec: int = 604800        # 7 ngày
    # Số event MỚI tối thiểu để còn gửi tin. Batch mà mọi event đều đã báo thì
    # không có gì mới để nói — im lặng, không gửi "0 event".
    dedup_min_events: int = 1
    extra_env: dict = field(default_factory=dict)


def load_config() -> Config:
    _load_dotenv()
    cfg = Config(
        bot_token=os.environ.get("ALERT_BOT_TOKEN", os.environ.get("BOT_TOKEN", "")),
        database_path=os.environ.get("ALERT_DB_PATH", "data/alerts.db"),
        evidence_root=os.environ.get("ALERT_EVIDENCE_ROOT", "data/evidence"),
        retention_days=int(os.environ.get("ALERT_RETENTION_DAYS", "90")),
        pairing_ttl_sec=int(os.environ.get("ALERT_PAIRING_TTL_SEC", "600")),
        reveal_ttl_sec=int(os.environ.get("ALERT_REVEAL_TTL_SEC", "600")),
        admin_token=os.environ.get("ALERT_ADMIN_TOKEN", ""),
        read_token=os.environ.get("ALERT_READ_TOKEN", ""),
        bot_polling=os.environ.get("ALERT_BOT_POLLING", "1") not in ("0", "false", "no"),
        max_alerts_per_request=int(os.environ.get("ALERT_MAX_ALERTS_PER_REQUEST", "50")),
        ingest_rate_per_min=int(os.environ.get("ALERT_INGEST_RATE_PER_MIN", "120")),
        register_rate_per_hour=int(os.environ.get("ALERT_REGISTER_RATE_PER_HOUR", "30")),
        preview_max=int(os.environ.get("ALERT_PREVIEW_MAX", "8")),
        preview_wait_sec=float(os.environ.get("ALERT_PREVIEW_WAIT_SEC", "2")),
        resend_window_sec=int(os.environ.get("ALERT_RESEND_WINDOW_SEC", "3600")),
        dedup_window_sec=int(os.environ.get("ALERT_DEDUP_WINDOW_SEC", "604800")),
        dedup_min_events=int(os.environ.get("ALERT_DEDUP_MIN_EVENTS", "1")),
    )
    if not cfg.bot_token:
        # Không có token: server vẫn chạy API, bot tắt (dev/kiểm thử nội bộ).
        cfg.bot_polling = False
    return cfg
