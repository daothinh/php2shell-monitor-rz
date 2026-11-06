"""FastAPI app: lifespan khởi tạo DB, bot polling và tác vụ dọn dẹp."""
import asyncio
import logging
from contextlib import asynccontextmanager
from zoneinfo import ZoneInfo

from fastapi import FastAPI

from . import db, migrate, preview
from .config import Config, load_config
from .routes import router
from .telegram import PairingBot, TelegramClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("alert-server")


def _prune_evidence(cfg: Config) -> None:
    """Delete evidence batch files older than the retention window.

    Layout: <root>/<project>/IP-LAN_<ip>_<host>_<user>/<batch>.jsonl — the
    batch filename carries the UTC timestamp (YYYYMMDDTHHMMSSZ), so file
    mtime decides what is expired.
    """
    if cfg.retention_days <= 0:
        return
    import time
    from pathlib import Path

    root = Path(cfg.evidence_root)
    if not root.is_dir():
        return
    cutoff = time.time() - cfg.retention_days * 86400
    for f in root.glob("*/*/*.jsonl"):
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
                f.parent.rmdir()  # only succeeds when the device folder is empty
        except OSError:
            continue


async def _cleanup_loop(cfg: Config) -> None:
    while True:
        try:
            db.cleanup(cfg.database_path, cfg.reveal_ttl_sec, cfg.retention_days)
            _prune_evidence(cfg)
            # reported_events phải có trần: không dọn thì mỗi event một dòng,
            # batch 88k hit sẽ làm bảng phình vô hạn.
            try:
                n = db.prune_reported_events(
                    cfg.database_path, int(cfg.dedup_window_sec or 604800))
                if n:
                    log.info("dọn %d ident dedup quá cửa sổ", n)
            except Exception:  # noqa: BLE001
                log.exception("dọn reported_events lỗi")
            # Vá dần lịch sử: alert cũ do monitor <= 1.4.2 gửi lên không có raw
            # row nào trong alert_hits. Chạy nền, mỗi vòng một lô nhỏ.
            try:
                fixed, rows = preview.backfill_alert_hits(cfg, cfg.database_path)
                if fixed:
                    log.info("vá alert_hits từ evidence: %d alert, %d row", fixed, rows)
            except Exception:  # noqa: BLE001 — housekeeping không được làm chết loop
                log.exception("vá alert_hits lỗi")
            # Alert bị hoãn vì thiếu raw: thử gửi bù mỗi vòng (evidence có thể
            # lên muộn, hoặc backfill vừa nạp raw từ file).
            try:
                n = await preview.flush_awaiting(cfg, cfg.database_path,
                                                 app.state.telegram, app.state.tz)
                if n:
                    log.info("gửi bù %d alert đang chờ raw", n)
            except Exception:  # noqa: BLE001
                log.exception("gửi bù alert lỗi")
        except Exception:  # noqa: BLE001
            log.exception("cleanup lỗi")
        await asyncio.sleep(900)  # 15 phút


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Honour a config injected by the host (tests/embedding); load from env otherwise.
    cfg: Config = getattr(app.state, "cfg", None) or load_config()
    if not cfg.bot_token:
        log.warning("ALERT_BOT_TOKEN chưa cấu hình — bot Telegram TẮT, chỉ API hoạt động")
    app.state.cfg = cfg
    if getattr(app.state, "tz", None) is None:
        try:
            app.state.tz = ZoneInfo(cfg.display_tz)
        except Exception:  # noqa: BLE001 — missing tzdata: fall back to UTC
            from datetime import timezone
            app.state.tz = timezone.utc
    db.init_db(cfg.database_path)

    # Projects paired before devices were registered at pair time have an
    # api_keys row but no devices row: /list showed them as "chưa khả dụng".
    # Rebuild those device rows from the key label (the machine's hostname).
    try:
        made = migrate.backfill_devices(cfg.database_path)
        if made:
            log.info("đã tạo %d thiết bị từ api_keys (pair trước bản vá)", made)
    except Exception as exc:  # noqa: BLE001 — housekeeping must not block startup
        log.warning("backfill thiết bị thất bại: %s", exc)

    # Fold IP-LAN_<ip>_<host>_<user> folders into IP-LAN_<ip>_<host>. Runs on
    # every start but is a no-op once the old layout is gone.
    try:
        merged = migrate.merge_user_folders(cfg.evidence_root)
        if merged:
            log.info("đã gộp %d thư mục evidence kiểu cũ", len(merged))
    except Exception as exc:  # noqa: BLE001 — never block startup on housekeeping
        log.warning("gộp thư mục evidence thất bại: %s", exc)

    # Vá NGAY một lô lịch sử lúc khởi động: alert cũ thiếu raw row thì /search và
    # /alerts/{id} vẫn mù cho tới vòng cleanup đầu tiên (15 phút).
    try:
        fixed, rows = preview.backfill_alert_hits(cfg, cfg.database_path)
        if fixed:
            log.info("vá alert_hits lúc khởi động: %d alert, %d row", fixed, rows)
    except Exception as exc:  # noqa: BLE001
        log.warning("vá alert_hits lúc khởi động thất bại: %s", exc)

    tg = getattr(app.state, "telegram", None) or TelegramClient(cfg.bot_token or "unset")
    app.state.telegram = tg
    tasks = [asyncio.create_task(_cleanup_loop(cfg), name="cleanup")]
    if cfg.bot_polling:
        bot = PairingBot(cfg, tg, cfg.database_path)
        tasks.append(asyncio.create_task(bot.run(), name="telegram-bot"))
        log.info("bot polling đang khởi động...")
    try:
        yield
    finally:
        for t in tasks:
            t.cancel()
        await tg.aclose()


app = FastAPI(
    title="Central Security Alert Server",
    version="1.3.0",
    description="Tiếp nhận alert bảo mật (php2shell-monitor) và bắn cảnh báo Telegram theo dự án.",
    lifespan=lifespan,
)
app.include_router(router)
