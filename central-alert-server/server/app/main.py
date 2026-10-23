"""FastAPI app: lifespan khởi tạo DB, bot polling và tác vụ dọn dẹp."""
import asyncio
import logging
from contextlib import asynccontextmanager
from zoneinfo import ZoneInfo

from fastapi import FastAPI

from . import db
from .config import Config, load_config
from .routes import router
from .telegram import PairingBot, TelegramClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("alert-server")


async def _cleanup_loop(cfg: Config) -> None:
    while True:
        try:
            db.cleanup(cfg.database_path, cfg.reveal_ttl_sec)
        except Exception:  # noqa: BLE001
            log.exception("cleanup lỗi")
        await asyncio.sleep(900)  # 15 phút


@asynccontextmanager
async def lifespan(app: FastAPI):
    cfg = load_config()
    if not cfg.bot_token:
        log.warning("ALERT_BOT_TOKEN chưa cấu hình — bot Telegram TẮT, chỉ API hoạt động")
    app.state.cfg = cfg
    try:
        app.state.tz = ZoneInfo(cfg.display_tz)
    except Exception:  # noqa: BLE001 — zoneinfo thiếu dữ liệu tz thì dùng UTC
        from datetime import timezone
        app.state.tz = timezone.utc
    db.init_db(cfg.database_path)

    tg = TelegramClient(cfg.bot_token or "unset")
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
