"""Chặn alert lặp: event đã báo trước thì không hiện lại trên Telegram.

VẤN ĐỀ THẬT
Monitor 1.4.2 không dedup ở nguồn: một webshell nằm yên trên đĩa sinh đúng một
nhóm event giống hệt nhau ở MỌI batch 5 phút. Bản 1.4.11 mới dedup theo
(path, đoạn code), nhưng máy khách còn ở 1.4.2 thì server là chốt chặn duy nhất.
Đo trên lab: 48 batch liên tiếp cho cùng một shell = 48 tin Telegram giống nhau.

VÌ SAO ĐẶT Ở SERVER CHỨ KHÔNG Ở FORMATTER
Formatter chỉ thấy một alert; nó không biết batch trước đã báo gì. Chỉ DB mới
biết. Vì vậy danh tính event được ghi lại mỗi lần gửi thành công, và lần sau
được đối chiếu trước khi dựng tin.

DANH TÍNH CỦA MỘT EVENT
    sha256(source | file | line | raw)

Gồm `raw` (đã có timestamp của dòng log) nên hai request giống nhau ở HAI thời
điểm khác nhau vẫn là hai event — chỉ dòng Y HỆT (cùng file, cùng số dòng, cùng
nội dung) mới bị coi là đã báo. Với hit không phải log (webroot pattern, proc),
`raw` không có timestamp nên ident ổn định qua các batch — đúng thứ cần chặn.

CỬA SỔ
Mặc định 7 ngày (`ALERT_DEDUP_WINDOW_SEC`). Không phải "mãi mãi": DB phải có
trần, và một sự cố lặp lại sau một tuần vẫn đáng thấy lại.
"""
import hashlib
import json
import logging
from typing import Iterable

from . import db
from .config import Config

log = logging.getLogger("alert-server.dedup")

DEFAULT_WINDOW_SEC = 7 * 86400


def ident(source: str, file: str, line: int, raw: str) -> str:
    """Danh tính ổn định của một event."""
    h = hashlib.sha256()
    h.update((source or "").encode("utf-8", "replace"))
    h.update(b"\x1f")
    h.update((file or "").encode("utf-8", "replace"))
    h.update(b"\x1f")
    h.update(str(int(line or 0)).encode())
    h.update(b"\x1f")
    h.update((raw or "").encode("utf-8", "replace"))
    return h.hexdigest()


def group_ident(g: dict) -> str:
    """Danh tính của một nhóm preview/event."""
    return ident(str(g.get("source") or ""), str(g.get("file") or ""),
                 int(g.get("line") or 0), str(g.get("raw") or ""))


def split_new(groups: Iterable[dict], seen: set) -> tuple[list[dict], int]:
    """Tách (nhóm chưa báo, số nhóm bị bỏ vì đã báo).

    Giữ nguyên thứ tự — tầng hiển thị đã sắp xếp theo mức ưu tiên.
    """
    fresh, dropped = [], 0
    local = set()
    for g in groups:
        k = group_ident(g)
        if k in seen or k in local:
            dropped += 1
            continue
        local.add(k)
        fresh.append(g)
    return fresh, dropped


def already_reported(cfg: Config, db_path: str, device_id: int,
                     groups: Iterable[dict]) -> set:
    """Tập ident trong `groups` đã được báo cho thiết bị này trong cửa sổ."""
    window = int(getattr(cfg, "dedup_window_sec", DEFAULT_WINDOW_SEC)
                 or DEFAULT_WINDOW_SEC)
    idents = [group_ident(g) for g in groups]
    if not idents:
        return set()
    return db.reported_idents(db_path, int(device_id), idents, window)


def remember(db_path: str, device_id: int, alert_id: int,
             groups: Iterable[dict]) -> int:
    """Ghi nhận các event VỪA được gửi để lần sau không báo lại."""
    rows = [(int(device_id), group_ident(g), int(alert_id),
             str(g.get("source") or ""), str(g.get("file") or ""),
             int(g.get("line") or 0))
            for g in groups
            if g.get("raw")]
    if not rows:
        return 0
    return db.record_reported_events(db_path, rows)


def apply(cfg: Config, db_path: str, device_id: int, alert: dict) -> int:
    """Lọc `alert["preview"]` bỏ event đã báo. Trả số nhóm bị bỏ.

    Đặt `alert["_duplicate_events"]` để formatter nêu đúng phần bị ẩn, và
    `alert["_event_total"]` theo số event MỚI — con số trên header phải khớp
    với những gì người trực ca thực sự nhận được.
    """
    groups = alert.get("preview") or []
    if not groups:
        return 0
    seen = already_reported(cfg, db_path, device_id, groups)
    fresh, dropped = split_new(groups, seen)
    if dropped:
        log.info("bỏ %d nhóm event đã báo trước (device=%s batch=%s)",
                 dropped, device_id, alert.get("batch_id"))
    alert["preview"] = fresh
    alert["_duplicate_events"] = dropped
    if fresh:
        # Số event mới: cộng hits của các nhóm còn lại (một nhóm = nhiều dòng
        # giống nhau), không dùng tổng cũ đã gồm phần bị bỏ.
        alert["_event_total"] = sum(int(g.get("hits") or 1) for g in fresh)
        alert["preview_meta"] = (f"{alert['_event_total']}|{len(fresh)}")
    else:
        alert["_event_total"] = 0
        alert["preview_meta"] = "0|0"
    return dropped


def summary(alert: dict) -> str:
    """Chuỗi JSON gọn để ghi log/DB về phần bị chặn."""
    return json.dumps({"duplicate_events": int(alert.get("_duplicate_events") or 0)},
                      ensure_ascii=False)


__all__ = ["ident", "group_ident", "split_new", "already_reported", "remember",
           "apply", "summary", "DEFAULT_WINDOW_SEC"]
