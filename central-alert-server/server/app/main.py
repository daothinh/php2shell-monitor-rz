"""FastAPI app: lifespan khởi tạo DB, bot polling và tác vụ dọn dẹp."""
import asyncio
import logging
from contextlib import asynccontextmanager
from zoneinfo import ZoneInfo

from fastapi import FastAPI

from . import db, migrate
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

    # Fold IP-LAN_<ip>_<host>_<user> folders into IP-LAN_<ip>_<host>. Runs on
    # every start but is a no-op once the old layout is gone.
    try:
        merged = migrate.merge_user_folders(cfg.evidence_root)
        if merged:
            log.info("đã gộp %d thư mục evidence kiểu cũ", len(merged))
    except Exception as exc:  # noqa: BLE001 — never block startup on housekeeping
        log.warning("gộp thư mục evidence thất bại: %s", exc)

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
    version="1.0.0",
    description="Tiếp nhận alert bảo mật (php2shell-monitor) và bắn cảnh báo Telegram theo dự án.",
    lifespan=lifespan,
)
app.include_router(router)
