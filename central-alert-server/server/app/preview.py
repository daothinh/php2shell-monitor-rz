"""Dựng lại nhóm event (preview) từ file evidence đã mirror trên server.

Vì sao cần: monitor <= 1.4.2 KHÔNG gửi `preview[]` trong alert — tính năng đó
chỉ có từ 1.4.3. Nhưng từ rất lâu (>= 1.1.0) agent đã upload evidence JSONL
đầy đủ qua kênh riêng `/api/v1/ingest-evidence`, và server ghi thẳng vào mirror:

    <root>/<project>/IP-LAN_<lan_ip>_<hostname>/<batch>.jsonl

Nghĩa là raw event LUÔN có trên server, chỉ là tin Telegram không đọc tới. Module
này bắc cầu: đọc file mirror của đúng batch rồi dựng `preview[]` y hệt những gì
monitor 1.4.3+ gửi kèm (cùng luật gộp trùng, cùng thứ tự ưu tiên), nên dự án còn
ở bản cũ vẫn nhận được tin nhắn có raw line mà không phải nâng cấp máy khách.

Luật gộp phải khớp `lib/preview.awk` của monitor, nếu không hai bên sẽ đếm khác
nhau và "… +N nhóm" sẽ sai:
  * khoá gộp = raw đã chuẩn hoá: mọi `[...]` -> `[ts]`, `sess_<id>` -> `sess_<id>`
  * hits  = số dòng cùng khoá
  * lines = số dòng có số dòng log (line > 0) trong nhóm
  * thứ tự: impact == "rce" trước, rồi hits giảm dần, rồi lần xuất hiện đầu
"""
import json
import logging
import re
from pathlib import Path
from typing import Any, Iterable

from . import db, dedup, evidence
from .config import Config

log = logging.getLogger("alert-server.preview")

_TS_RE = re.compile(r"\[[^\]]*\]")
_SESS_RE = re.compile(r"sess_[A-Za-z0-9]+")

# Trần đọc một file evidence khi dựng preview. Batch lớn nhất từng thấy là 178 MB
# / 363k dòng; đọc hết mỗi alert làm ingest chậm mà không thêm thông tin (chỉ cần
# tối đa `max_groups` nhóm + số nhóm). Vượt trần thì dừng và báo là đã cắt.
MAX_READ_BYTES = 64 * 1024 * 1024


def _key(raw: str) -> str:
    return _SESS_RE.sub("sess_<id>", _TS_RE.sub("[ts]", raw))


def groups_from_records(records: Iterable[dict], max_groups: int = 8
                        ) -> tuple[list[dict], int]:
    """Cùng luật gộp với preview.awk, nhưng trên các dict đã parse sẵn."""
    seen: dict[str, dict] = {}
    order: list[str] = []
    total = 0
    for rec in records:
        if not isinstance(rec, dict):
            continue
        raw = str(rec.get("raw") or "")
        rule = str(rec.get("rule_id") or "")
        if not raw or not rule:
            continue
        total += 1
        k = _key(raw)
        g = seen.get(k)
        if g is None:
            g = {
                "rule_id": rule,
                "hits": 0,
                "severity": str(rec.get("severity") or "").upper(),
                "impact": rec.get("impact") or "",
                "source": rec.get("source") or "",
                "file": rec.get("file") or "",
                "line": int(rec.get("line") or 0),
                "lines": 0,
                "raw": raw,
            }
            seen[k] = g
            order.append(k)
        g["hits"] += 1
        if int(rec.get("line") or 0) > 0:
            g["lines"] += 1
        if rec.get("impact") == "rce":
            g["impact"] = "rce"
    ranked = sorted(
        (seen[k] for k in order),
        key=lambda g: (0 if g["impact"] == "rce" else 1, -g["hits"]),
    )
    return ranked[:max_groups], total


def groups_from_jsonl(path: str | Path, max_groups: int = 8,
                      max_bytes: int = MAX_READ_BYTES) -> tuple[list[dict], int, bool]:
    """Đọc evidence JSONL -> (nhóm, tổng hit, đã cắt?).

    Trả về tối đa `max_groups` nhóm đã sắp xếp, cùng tổng số hit đã đếm được
    (dùng cho preview_meta khi alert không mang `hits`).
    """
    p = Path(path)
    if not p.is_file():
        return [], 0, False

    recs: list[dict] = []
    truncated = False
    read = 0
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                read += len(line)
                if read > max_bytes:
                    truncated = True
                    break
                line = line.strip()
                if not line or '"raw"' not in line:
                    continue
                try:
                    recs.append(json.loads(line))
                except ValueError:
                    continue
    except OSError as exc:
        log.warning("không đọc được evidence %s: %s", p, exc)
        return [], 0, False

    groups, total = groups_from_records(recs, max_groups)
    return groups, total, truncated


def count_events(path: str | Path, max_bytes: int = MAX_READ_BYTES,
                 cap_records: int = 500000) -> int:
    """Số event THẬT trong file evidence: dedup theo danh tính, không theo số dòng.

    Vì sao cần con số riêng thay vì đếm dòng: cùng một sự kiện có thể tới server
    nhiều lần (agent gửi lại sau khi mất mạng, cùng một dòng log được hai plugin
    đọc, hoặc monitor đếm hits theo rule và một dòng khớp 2 rule bị tính 2).
    Người trực ca cần con số "server thực sự nhận được bao nhiêu event", không
    phải tổng các bộ đếm có thể chồng nhau.

    Danh tính = (source, file, line, raw): hai request giống nhau ở HAI dòng khác
    nhau vẫn là hai event (đúng bản chất), còn một dòng bị đẩy lên hai lần chỉ là
    một.

    Bounded: dừng ở `max_bytes` hoặc `cap_records`, đủ cho batch lớn nhất từng
    thấy (178 MB / 363k dòng) mà không giữ cả file trong RAM.
    """
    p = Path(path)
    if not p.is_file():
        return 0
    seen: set[tuple] = set()
    read = 0
    n = 0
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                read += len(line)
                if read > max_bytes or n >= cap_records:
                    break
                if '"raw"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(rec, dict) or not rec.get("raw"):
                    continue
                n += 1
                line_no = int(rec.get("line") or 0)
                seen.add((str(rec.get("source") or ""), str(rec.get("file") or ""),
                          line_no if line_no > 0 else 0, str(rec.get("raw") or "")))
    except OSError as exc:
        log.warning("không đếm được event trong %s: %s", p, exc)
        return 0
    return len(seen)


def iter_records(path: str | Path, cap: int = 2000,
                 max_bytes: int = MAX_READ_BYTES) -> Iterable[dict]:
    """Sinh từng record của file evidence (tối đa `cap`), bỏ dòng hỏng."""
    p = Path(path)
    if not p.is_file():
        return
    read = 0
    n = 0
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                read += len(line)
                if read > max_bytes or n >= cap:
                    return
                line = line.strip()
                if not line or '"raw"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(rec, dict) or not rec.get("raw"):
                    continue
                n += 1
                yield rec
    except OSError as exc:
        log.warning("không đọc được evidence %s: %s", p, exc)
        return


def evidence_file(cfg: Config, project_name: str, alert: dict) -> Path:
    """Đường dẫn mirror của batch này (công khai cho routes/backfill dùng)."""
    return _evidence_file(cfg, project_name, alert)


def find_evidence(cfg: Config, project_name: str, batch_id: str,
                  device_name: str = "") -> Path | None:
    """Tìm file evidence của một batch trên mirror, không cần biết lan_ip.

    Đường dẫn chuẩn là <root>/<project>/IP-LAN_<ip>_<host>/<batch>.jsonl, nhưng
    alert cũ không lưu lan_ip nên không dựng lại được chính xác — quét theo batch
    trong thư mục dự án (khớp thêm device nếu có) là đủ và không phụ thuộc IP.
    """
    root = Path(cfg.evidence_root) / db.slug(project_name)
    name = db.slug(str(batch_id or "batch")) + ".jsonl"
    if not root.is_dir():
        return None
    hits = sorted(root.glob(f"*/{name}"))
    if not hits:
        return None
    if device_name:
        want = db.slug(device_name)
        for p in hits:
            if want and want in p.parent.name:
                return p
    return hits[0]


def _evidence_file(cfg: Config, project_name: str, alert: dict) -> Path:
    """Đường dẫn mirror của đúng batch này (cùng công thức với routes.py)."""
    label = evidence.device_label(alert)
    batch = db.slug(str(alert.get("batch_id") or "batch"))
    return evidence.evidence_path(cfg, project_name, label, batch)


def attach(cfg: Config, project_name: str, alert: dict,
           max_groups: int | None = None) -> bool:
    """Gắn `preview[]` + `preview_meta` từ file evidence mirror. True nếu gắn được.

    Không đụng gì khi alert đã có preview (monitor >= 1.4.3 tự gửi), hoặc khi
    file evidence chưa lên tới server (agent upload sau alert vài trăm ms).
    """
    if alert.get("preview"):
        return False
    limit = int(max_groups if max_groups is not None else cfg.preview_max)
    if limit <= 0:
        return False

    # 1. evidence[] inline (agent có MAX_EVIDENCE_INLINE>0): không cần chạm đĩa.
    inline = alert.get("evidence")
    if isinstance(inline, list) and inline:
        groups, total = groups_from_records(inline, limit)
        if groups:
            alert["preview"] = groups
            alert["preview_meta"] = f"{total}|{len(groups)}"
            alert["_preview_from_evidence"] = True
            alert["_preview_source"] = "inline"     # evidence[] trong payload
            return True

    # 2. mirror file: đường đi của mọi alert thật (MAX_EVIDENCE_INLINE=0).
    #    Đường dẫn chuẩn dựng từ lan_ip + hostname của alert; nếu lệch (máy đổi
    #    IP/hostname sau khi evidence đã lên) thì quét lại theo batch.
    path = _evidence_file(cfg, project_name, alert)
    if not path.is_file():
        alt = find_evidence(cfg, project_name, str(alert.get("batch_id") or ""),
                            str(alert.get("device") or alert.get("host") or ""))
        if alt is None:
            return False
        path = alt
    groups, total, truncated = groups_from_jsonl(path, limit)
    if not groups:
        return False
    alert["preview"] = groups
    alert["preview_meta"] = f"{total or int(alert.get('hits') or 0)}|{len(groups)}"
    # Con số hiển thị trên tin Telegram: event THẬT server nhận (dedup), không
    # phải tổng bộ đếm rule của monitor. Đếm trên mirror — nguồn duy nhất có đủ
    # mọi raw của batch.
    # event_total() một mình không đủ: mirror có thể đã bị cắt (agent cũ giới
    # hạn 500 dòng), nên con số này là SÀN, không phải trần.
    alert["_event_total"] = count_events(path) or total
    alert["_preview_from_evidence"] = True
    alert["_preview_source"] = "evidence"           # file mirror trên server
    alert["_evidence_mirror"] = str(path)
    if truncated:
        log.info("preview từ evidence %s bị cắt ở %d MB", path, MAX_READ_BYTES // 1048576)
    return True


def backfill_alert_hits(cfg: Config, db_path: str, limit_alerts: int = 500,
                        cap: int = 2000) -> tuple[int, int]:
    """Nạp alert_hits cho các alert ĐÃ LƯU mà thiếu raw thật.

    Alert do monitor <= 1.4.2 gửi lên mang evidence[] rỗng (raw đi kênh riêng),
    nên trước bản vá DB chỉ có một row rác rule_id=NULL: /alerts/{id} và /search
    mù với đúng những batch quan trọng nhất. Hàm này đọc lại evidence mirror và
    dựng row thật. Idempotent: alert đã có raw thì bỏ qua.

    Trả (số alert đã vá, số row đã thêm).
    """
    fixed = rows_added = 0
    with db.connect(db_path) as conn:
        todo = conn.execute(
            "SELECT a.id, a.batch_id, a.project_id, p.project_name, d.device_name"
            "  FROM alerts a"
            "  JOIN projects p ON p.id = a.project_id"
            "  JOIN devices d ON d.id = a.device_id"
            " WHERE NOT EXISTS (SELECT 1 FROM alert_hits h"
            "                    WHERE h.alert_id = a.id AND h.raw IS NOT NULL"
            "                      AND h.raw <> '')"
            " ORDER BY a.id DESC LIMIT ?",
            (int(limit_alerts),),
        ).fetchall()

    for r in todo:
        path = find_evidence(cfg, r["project_name"], r["batch_id"], r["device_name"])
        if path is None:
            continue
        n = db.backfill_hits(db_path, int(r["id"]),
                             iter_records(path, cap=cap), cap=cap)
        if n:
            fixed += 1
            rows_added += n
            # alert tới trước khi file evidence lên -> evidence_file rỗng. Vá
            # luôn con trỏ đó để lần tra cứu sau biết raw nằm ở đâu.
            with db.connect(db_path) as conn:
                conn.execute(
                    "UPDATE alerts SET evidence_file = ?"
                    " WHERE id = ? AND (evidence_file IS NULL OR evidence_file = '')",
                    (str(path), int(r["id"])),
                )
    return fixed, rows_added


def alert_from_row(row) -> dict:
    """Row alerts (JOIN project/device) -> dict đúng shape format_alert()."""
    import json as _json
    a = dict(row)
    try:
        a["rules"] = _json.loads(a.get("rules") or "[]")
    except (TypeError, ValueError):
        a["rules"] = []
    a["hits"] = a.get("hit_count") or 0
    for k in ("lan_ip", "hostname", "user", "os", "env"):
        if a.get(k):
            a[k] = a[k]
    # containers lưu dạng JSON array trong 1 cột: phải parse lại, nếu không
    # format_alert thấy chuỗi và dòng 🐳 Container biến mất khỏi tin gửi bù.
    try:
        c = _json.loads(a.get("containers") or "[]")
        a["containers"] = [str(x) for x in c] if isinstance(c, list) else []
    except (TypeError, ValueError):
        a["containers"] = []
    return a


async def flush_awaiting(cfg: Config, db_path: str, tg, tz, limit: int = 200) -> int:
    """Gửi bù các alert đang chờ raw. Trả số tin đã gửi.

    Chỉ gửi khi dựng được preview[] thật từ evidence mirror (hoặc từ alert_hits
    đã lưu). Vẫn không có raw thì để nguyên trong hàng đợi — không bao giờ gửi
    một tin không có bằng chứng.
    """
    from .telegram import format_alert, has_raw

    sent_n = 0
    window = int(getattr(cfg, "resend_window_sec", 3600) or 3600)
    # Chốt sổ trước: alert tồn đọng quá cửa sổ bị đánh dấu messages=2, không bao
    # giờ được gửi nữa. Không có bước này thì một lần update server trên DB có
    # hàng đợi cũ sẽ phát lại toàn bộ cảnh báo lịch sử vào chat khách.
    stale = db.expire_stale_unsent(db_path, window)
    if stale:
        log.warning("bỏ %d alert tồn đọng quá %ds — không gửi lại lịch sử",
                    stale, window)
    for row in db.alerts_awaiting_raw(db_path, limit, max_age_sec=window):
        alert = alert_from_row(row)
        path = find_evidence(cfg, row["project_name"], str(row["batch_id"] or ""),
                             str(row["device_name"] or ""))
        if path is not None:
            groups, total, _cut = groups_from_jsonl(path, int(cfg.preview_max or 8))
            if groups:
                alert["preview"] = groups
                alert["preview_meta"] = f"{total}|{len(groups)}"
        if not alert.get("preview"):
            # alert_hits đã lưu (nếu backfill kịp chạy) cũng là raw thật
            groups, total = groups_from_records(
                db.alert_hits_rows(db_path, int(row["id"])),
                int(cfg.preview_max or 8))
            if groups:
                alert["preview"] = groups
                alert["preview_meta"] = f"{total}|{len(groups)}"
        if not has_raw(alert):
            continue        # vẫn không có bằng chứng -> giữ trong hàng đợi
        # Bỏ event đã báo trước (giống đường ingest): gửi bù không được hồi sinh
        # một nhóm event mà chat đã đọc.
        dropped = dedup.apply(cfg, db_path, int(row["device_id"]), alert)
        if dropped and not (alert.get("preview") or []):
            db.mark_alert_suppressed(db_path, int(row["id"]))
            log.info("gửi bù bỏ qua alert_id=%s: toàn bộ %d nhóm đã báo trước",
                     row["id"], dropped)
            continue
        ok, _err = await tg.send_message(row["telegram_chat_id"],
                                         format_alert(row["project_name"], alert, tz))
        db.mark_alert_sent(db_path, int(row["id"]), ok,
                           str(path) if path is not None else "")
        if ok:
            dedup.remember(db_path, int(row["device_id"]), int(row["id"]),
                           alert.get("preview") or [])
        if ok:
            sent_n += 1
    return sent_n


__all__: list[Any] = ["groups_from_records", "groups_from_jsonl", "attach",
                     "iter_records", "evidence_file", "find_evidence",
                     "backfill_alert_hits", "alert_from_row", "flush_awaiting",
                     "MAX_READ_BYTES"]
