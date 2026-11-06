"""Telegram: client gửi tin + bot polling xử lý mã pairing + format alert."""
import asyncio
import html
import json
import logging
import re
from datetime import datetime, timezone
from typing import Any, Optional
from zoneinfo import ZoneInfo

import httpx

from . import db, legacy
from .config import Config
from .security import AttemptGuard, gen_api_key, sha256_hex

log = logging.getLogger("alert-server.telegram")

TG_API = "https://api.telegram.org/bot{token}/{method}"
CODE_RE = re.compile(
    r"\bSEC-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b"
)

_SEV_EMOJI = {
    "CRITICAL": "🚨", "HIGH": "⚠️", "MEDIUM": "🟡", "MODERATE": "🟡",
    "LOW": "ℹ️", "INFO": "ℹ️",
}
_SEV_RANK = {"CRITICAL": 5, "HIGH": 4, "MEDIUM": 3, "MODERATE": 3, "LOW": 2, "INFO": 1}

# Câu "Sự kiện" trên mọi alert. Operator chốt: một câu duy nhất, không suy ra
# từ severity — "Mức độ" không còn hiện trên tin nhắn nên câu này cũng không
# được đổi theo severity nữa. Severity vẫn lưu trong DB để lọc/tra cứu.
EVENT_TEXT = "Phát hiện nghi vấn khai thác php2Shell"

# Alert headline: exactly two messages.
#   "Server bị chiếm quyền (RCE)" — any hit from an exploitation-success rule
#   (T3: webshell dropped, backdoor, host exec, fpm child shell, reverse shell).
#   "Server đang bị khai thác php2shell" — everything else, i.e. any batch with
#   more than 2 distinct rules (T1 pre-exploit probes / T2 in-progress signals).
# CRITICAL = the server IS compromised, not "is being attacked". A rule belongs
# here only when its own evidence proves code execution already happened or a
# payload is already sitting on disk / in a session file. Anything that is still
# just a probe stays out, however loud it is.
RCE_RULES = frozenset({
    "P2S-020",  # webroot file written/changed        -> shell landed
    "P2S-021",  # host process exec (auditd)           -> command ran
    "P2S-022",  # auto_prepend_file injected           -> persistent backdoor
    "P2S-024",  # php-fpm spawned shell child          -> command ran
    "P2S-025",  # reverse shell / post-exploitation    -> channel open
    "P2S-056",  # webshell pattern inside webroot      -> shell on disk
    "P2S-057",  # LFI tra 2xx + tham so nhan absolute path -> file da doc duoc
})
# Deliberately NOT here: P2S-050 / P2S-051 / P2S-054. Those fire on every LFI
# *attempt* (a request URI naming a session file or a php:// wrapper). They are
# the attack in progress, not proof it worked — including them would paint every
# noisy batch CRITICAL and bury the one batch where a shell really landed.
#
# P2S-057 là ranh giới: cùng một URI, 404 là "đang thử", 2xx là "đã đọc được".
# Rule này chỉ fire khi server thật sự trả nội dung file, nên nó là bằng chứng
# đọc file thành công — cùng hạng với shell đã lên đĩa, không phải dò quét.


def _split_ids(raw: Any) -> set[str]:
    """Split a rule_id field into individual ids.

    The monitor de-duplicates events: one raw log line that satisfies several
    rules carries them merged as "P2S-050,P2S-051". Treating that as a single
    string silently broke RCE detection (a merged "P2S-050,P2S-051" never
    matched the RCE set), so always split on the comma.
    """
    out: set[str] = set()
    for part in str(raw or "").split(","):
        part = part.strip()
        if part:
            out.add(part)
    return out


def _alert_rule_ids(alert: dict) -> set[str]:
    """Every rule_id present in the alert (evidence[] preferred, else counters)."""
    ids: set[str] = set()
    for h in alert.get("evidence") or []:
        if isinstance(h, dict) and h.get("rule_id"):
            ids |= _split_ids(h["rule_id"])
    if not ids:  # payload without evidence[]: fall back to the rule counters
        for r in alert.get("rules") or []:
            if isinstance(r, dict) and r.get("rule_id"):
                ids |= _split_ids(r["rule_id"])
        if alert.get("rule_id"):
            ids |= _split_ids(alert["rule_id"])
    return ids


def is_rce(alert: dict) -> bool:
    """True when the evidence proves the box is already compromised."""
    return bool(_alert_rule_ids(alert) & RCE_RULES)


def has_raw(alert: dict) -> bool:
    """Alert có raw event thật để hiển thị không.

    BẤT BIẾN NGHIỆP VỤ: alert Telegram phải kèm raw (bằng chứng). Không có raw
    thì KHÔNG gửi — một tin chỉ có "N events" mà không có dòng log nào khiến
    sysadmin hiểu sai (không biết máy nào, file nào, request nào) và làm mất
    niềm tin vào kênh cảnh báo. Nơi gọi phải hoãn, không được gửi.
    """
    return bool(_preview_groups(alert))


def _sev(a: dict) -> str:
    s = str(a.get("severity") or "").upper()
    return s if s in _SEV_EMOJI else "INFO"


def _parse_ts(ts_raw: Any) -> Optional[datetime]:
    s = str(ts_raw or "")
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        try:  # định dạng CLF-ish 2026-10-23 14:02:11
            dt = datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
        return dt.replace(tzinfo=timezone.utc)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _headline(alert: dict) -> str:
    """Sự kiện hiển thị trên mọi alert.

    Operator chốt: MỌI alert đều dùng đúng một câu, không phân biệt severity —
    "Mức độ" không còn hiện trên tin nhắn nên câu này cũng không được suy ra từ
    severity nữa. Severity vẫn lưu trong DB để lọc/tra cứu trên server.
    """
    return EVENT_TEXT


# Giới hạn Telegram: 4096 ký tự, đo SAU khi parse entity. Tag HTML không tính,
# nên budget phải tính trên bản đã bỏ tag — nếu đo trên source sẽ tưởng thiếu
# chỗ mà cắt oan (đo thật: alert 1563 ký tự source chỉ còn 1243 khi parse).
TG_LIMIT = 4096

# Mức tối thiểu của một dòng raw để còn đáng cắt mà hiện; dưới ngưỡng này thì
# thà bỏ event và báo "… +N" còn hơn hiện một mẩu vô nghĩa.
MIN_RAW_CHARS = 40

# Trần hiển thị khối Event logs. Operator chốt: tối đa 5 path, tối đa 3 event
# mỗi path; thêm trần tổng để một batch có 5 path vẫn không phình tin.
PREVIEW_PATHS = 5
PREVIEW_EVENTS_PER_PATH = 3
PREVIEW_EVENTS_TOTAL = 15

# Nhãn dòng cảnh báo. Trước đây là "Sự kiện"; operator đổi thành "Cảnh báo" vì
# đây là tin cảnh báo an ninh, không phải bản kê sự kiện đã xảy ra.
ALERT_LABEL = "Cảnh báo"

_TAG_RE = re.compile(r"</?[a-zA-Z][^>]*>")


def parsed_len(text: str) -> int:
    """Độ dài Telegram thực sự đếm: bỏ tag HTML, giải entity."""
    return len(html.unescape(_TAG_RE.sub("", text)))


def _esc(s: Any) -> str:
    return html.escape(str(s if s is not None else ""), quote=False)


# ------------------------------------------------------------------ timeline
# "Phần timeline được bôi đen và in đậm": Telegram HTML không có highlight, nên
# biểu diễn bằng <b> đúng khoảng thời gian trong dòng log. Mọi định dạng timestamp
# mà monitor đẩy lên đều phải khớp — access log CLF (có/không ngoặc), ISO của
# journald/docker (có nano + offset), FPM, và syslog cổ điển.
_TS_PATTERNS = (
    # [05/Nov/2026:04:11:02 +0000]
    re.compile(r"\[\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2}(?:\s+[+-]\d{4})?\]"),
    # 05/Nov/2026:04:11:02 +0000   (nginx log_format không ngoặc)
    re.compile(r"\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2}(?:\s+[+-]\d{4})?"),
    # 2026-11-04T22:33:11.118859+07:00 / 2026-11-05T07:43:31Z
    re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"),
    # [05-Nov-2026 07:43:31 UTC]   (PHP-FPM)
    re.compile(r"\[\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}:\d{2}(?:\s+[A-Za-z]{2,5})?\]"),
    # Nov  5 07:43:31   (syslog)
    re.compile(r"\b[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\b"),
)


def _timeline_span(raw: str) -> Optional[tuple[int, int]]:
    """Khoảng ký tự của mốc thời gian SỚM NHẤT trong dòng log (None nếu không có)."""
    best: Optional[tuple[int, int]] = None
    for pat in _TS_PATTERNS:
        m = pat.search(raw)
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), m.end())
    return best


def mark_timeline(raw: str) -> str:
    """Escape raw và in đậm đúng phần mốc thời gian.

    Escape phải làm SAU khi tách chuỗi (không phải trước): &lt; dài hơn < nên nếu
    escape trước rồi mới cắt theo offset thì mốc thời gian bị lệch và có thể cắt
    vào giữa một entity.
    """
    span = _timeline_span(raw)
    if span is None:
        return _esc(raw)
    s, e = span
    return f"{_esc(raw[:s])}<b>{_esc(raw[s:e])}</b>{_esc(raw[e:])}"


# ------------------------------------------------------------------- events
def _preview_groups(alert: dict) -> list[dict]:
    """Các nhóm event monitor đã gộp sẵn (alert["preview"]).

    Monitor gửi kèm tối đa ALERT_PREVIEW_MAX nhóm, đã de-dup và xếp nhóm
    impact=rce lên đầu. Server chỉ render, không gộp lại.
    """
    out = []
    for g in alert.get("preview") or []:
        if not isinstance(g, dict):
            continue
        raw = str(g.get("raw") or "")
        if not raw:
            continue
        out.append({
            "raw": raw,
            "source": str(g.get("source") or ""),
            "file": str(g.get("file") or ""),
            "line": int(g.get("line") or 0),
            "lines": int(g.get("lines") or 0),
            "hits": int(g.get("hits") or 1),
            "rce": str(g.get("impact") or "") == "rce",
        })
    out.sort(key=lambda g: (0 if g["rce"] else 1, -g["hits"]))
    return out


def _event_identity(e: dict) -> tuple:
    """Danh tính của MỘT event thật: nguồn + file + dòng + nội dung.

    Dùng để chặn "hit ảo": agent gửi lại cùng payload, hoặc cùng một dòng log
    được đọc bởi hai plugin, sẽ có cùng danh tính và chỉ được đếm một lần. Hai
    request giống nhau ở HAI dòng khác nhau vẫn là hai event (đúng bản chất).
    """
    raw = str(e.get("raw") or "")
    line = int(e.get("line") or 0)
    if line > 0:
        return (str(e.get("source") or ""), str(e.get("file") or ""), line, raw)
    return (str(e.get("source") or ""), str(e.get("file") or ""), 0, raw)


def event_total(alert: dict, groups: Optional[list[dict]] = None) -> int:
    """Tổng event THẬT SỰ server nhận được trong cửa sổ scan.

    Thứ tự tin cậy (cao -> thấp):
      1. `_event_total` do ingest/attach tính từ toàn bộ raw đã nhận (dedup);
      2. `evidence[]` trong payload/DB: đếm theo danh tính, bỏ bản trùng;
      3. `preview_meta` = "<hits>|<nhóm>" do monitor tính trên toàn file evidence;
      4. `hits` counter của alert.
    Không bao giờ in "0 events" khi alert có event: đó là lời nói dối về sự kiện
    và từng làm người trực ca tưởng monitor không thấy gì.
    """
    if alert.get("_event_total") is not None:
        try:
            n = max(0, int(alert["_event_total"]))
            # Mirror có thể BỊ CẮT (monitor cũ giới hạn evidence 500 dòng:
            # alerts.evidence_truncated=1, đo thật có batch 88 707 hit / 500 dòng
            # raw). Đếm trên mirror khi đó là báo thấp hơn sự thật, nên lấy con
            # số lớn hơn giữa mirror và counter của monitor — không bao giờ nói
            # ít event hơn những gì đã xảy ra.
            hits = int(alert.get("hits") or alert.get("hit_count") or 0)
            return max(n, hits)
        except (TypeError, ValueError):
            pass

    ev = alert.get("evidence")
    if isinstance(ev, list) and ev:
        return len({_event_identity(e) for e in ev if isinstance(e, dict)})

    groups = groups if groups is not None else _preview_groups(alert)
    try:
        meta = str(alert.get("preview_meta") or "")
        if "|" in meta:
            n = int(meta.split("|", 1)[0])
            if n > 0:
                return n
    except (TypeError, ValueError):
        pass

    try:
        n = int(alert.get("hits") or alert.get("hit_count") or 0)
    except (TypeError, ValueError):
        n = 0
    if n <= 0:
        n = len(groups)
    return n


def _path_of(g: dict) -> str:
    """Khoá nhóm của một event: đường dẫn file, hoặc tên nguồn khi không có file.

    Nhóm không có file (vd hit từ /proc — dữ liệu process, không thuộc file log
    nào) thì khoá là tên source. Nó KHÔNG được in dưới nhãn "Path" (xem
    _source_line): nhãn đó hứa một đường dẫn tuyệt đối.
    """
    return g["file"] or g["source"] or ""


def group_by_path(groups: list[dict], max_paths: int = PREVIEW_PATHS,
                  per_path: int = PREVIEW_EVENTS_PER_PATH,
                  max_total: int = PREVIEW_EVENTS_TOTAL) -> list[dict]:
    """Gom event theo path, chọn tối đa <max_paths> path tiêu biểu.

    Tiêu biểu = có bằng chứng RCE trước, rồi tổng số lần khớp giảm dần, rồi lần
    xuất hiện đầu. Trong mỗi path giữ tối đa <per_path> event cùng thứ tự đó.
    Giữ nguyên thứ tự chọn để tin nhắn ổn định giữa các lần render cùng dữ liệu.
    """
    order: list[str] = []
    buckets: dict[str, list[dict]] = {}
    for g in groups:
        path = _path_of(g)
        if path not in buckets:
            buckets[path] = []
            order.append(path)
        buckets[path].append(g)

    ranked = sorted(
        order,
        key=lambda p: (
            0 if any(g["rce"] for g in buckets[p]) else 1,
            -sum(g["hits"] for g in buckets[p]),
            order.index(p),
        ),
    )

    out: list[dict] = []
    used = 0
    for path in ranked[:max_paths]:
        evs = sorted(buckets[path], key=lambda g: (0 if g["rce"] else 1, -g["hits"]))
        take = evs[:max(0, per_path)]
        room = max_total - used
        if room <= 0:
            break
        take = take[:room]
        if not take:
            continue
        used += len(take)
        out.append({
            "path": path,
            "source": next((g.get("source") for g in buckets[path] if g.get("source")), ""),
            "events": take,
            "hidden_events": len(evs) - len(take),
            "hits": sum(g["hits"] for g in buckets[path]),
        })
    return out


# Path phải là đường dẫn tuyệt đối của một FILE thật. Đây là validate ở tầng
# hiển thị, không phải tầng phát hiện: monitor cũ từng gửi chuỗi mô tả
# ("journalctl -k") vào field `file`, và người trực ca nhận alert không biết mở
# file nào để tra. Không đạt -> KHÔNG in dòng "Path" giả, chỉ in nguồn thật.
_ABS_PATH_RE = re.compile(r"^(/|container:[^:]+:|docker:[^:]+:)[^\s]")


_DOCKER_ID_RE = re.compile(r"^docker:[^:]+:[0-9a-f]{12}:(/\S+)$")
_CONTAINER_PATH_RE = re.compile(r"^container:[^:]+:(/\S+)$")


def display_path(path: str) -> str:
    """Chuẩn hoá giá trị `file` thành đường dẫn THẬT để in dưới nhãn "Path".

    Gồm cả việc dịch các dạng cũ của monitor 1.4.2 (xem app/legacy.py):
      docker:<tên>:<cid12>    -> /var/lib/docker/containers/<cid12>*/<cid12>*-json.log
      container:<tên>:<cid12> -> cùng file json log (1.4.2 không ghi path trong)
      journalctl -k           -> /var/log/journal/*/system.journal
    Dạng mới đã có đường dẫn đầy đủ thì giữ nguyên.
    """
    return legacy.resolve_file(path)


def is_valid_path(path: str) -> bool:
    """`file` có dịch được thành đường dẫn tuyệt đối tới một file thật không?

    Giá trị mô tả ("kernel", "docker", "syslog") KHÔNG hợp lệ: nhãn "Path" hứa
    một đường dẫn, người trực ca sẽ đi tìm file không tồn tại. Dạng cũ của 1.4.2
    thì được DỊCH (xem app/legacy.py) chứ không bị bỏ.
    """
    p = (path or "").strip()
    if not p:
        return False
    if p.startswith("container:"):
        # Dạng mới: container:<tên>:<path tuyệt đối bên trong container>.
        if _CONTAINER_PATH_RE.match(p):
            return True
        # Dạng 1.4.2: container:<tên>:<cid12> — dịch sang json log của container.
        return bool(legacy.cid12_of(p))
    resolved = legacy.resolve_file(p)
    if not resolved:
        return False
    return resolved.startswith("/") or bool(_CONTAINER_PATH_RE.match(resolved))


def _path_line(path: str) -> str:
    """Một dòng nhãn `Path: <code>/abs/path</code>` — không đánh số.

    Operator bỏ số thứ tự: "Path 1/Path 2" không mang thông tin (thứ tự đã được
    thể hiện bằng vị trí khối), còn số thứ tự làm người đọc tưởng đó là một
    trường dữ liệu. Tên file mới là thứ cần đọc.
    """
    if not is_valid_path(path):
        return ""
    return f"<b>Path:</b> <code>{_esc(display_path(path))}</code>"


def _source_line(source: str) -> str:
    """Nhóm không có đường dẫn file: nêu NGUỒN, tách hẳn khỏi nhãn "Path".

    Không được in "Path: kernel" hay "Path: journalctl -k": nhãn Path hứa một
    đường dẫn tuyệt đối, và người trực ca sẽ đi tìm file không tồn tại. Nguồn là
    khái niệm khác (procfs, journald, registry nội bộ) nên phải có nhãn khác.
    """
    src = (source or "").strip()
    return f"<i>Nguồn: {_esc(src)}</i>" if src else ""


def _event_line(g: dict) -> str:
    """Một event trên một dòng; timeline in đậm; ×N khi nhóm đại diện nhiều lần."""
    body = mark_timeline(g["raw"])
    if g["hits"] > 1:
        body += f" ×{g['hits']}"
    return body


def _tail(more_paths: int, more_events: int) -> str:
    parts = []
    if more_paths > 0:
        parts.append(f"+{more_paths} path")
    if more_events > 0:
        parts.append(f"+{more_events} event")
    return f"<i>… {' / '.join(parts)}</i>" if parts else ""


def _fit_raw(raw: str, budget: int) -> str:
    """Tiền tố dài nhất của raw (đã in đậm timeline) vừa <budget> ký tự hiển thị."""
    if parsed_len(_event_line({"raw": raw, "hits": 1})) <= budget:
        return mark_timeline(raw)
    lo, hi = 0, len(raw)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if parsed_len(mark_timeline(raw[:mid]) + "…") <= budget:
            lo = mid
        else:
            hi = mid - 1
    return mark_timeline(raw[:lo] + "…") if lo > 0 else ""


def _container_list(alert: dict) -> list[str]:
    """Tên container của alert, chịu được cả list lẫn chuỗi JSON, kèm cid12.

    Hai việc, cả hai đều là lỗi thật đã thấy:

    1. Cột `alerts.containers` là TEXT chứa JSON array, nên đường đọc lại từ DB
       (gửi bù, resend) đưa vào một CHUỖI. Lặp qua chuỗi thì Python lặp từng KÝ
       TỰ và tin in ra "[, ", d, r, i…" (alert 174).

    2. Monitor 1.4.2 có lúc chỉ gửi tên trần ("drill-dwva"), không kèm cid12.
       Operator cần cid12 để phân biệt hai container TRÙNG TÊN trên hai máy
       khác nhau. cid12 lấy từ chính field `file` của các hit trong alert đó —
       dữ liệu có thật, không suy đoán (xem app/legacy.py).
    """
    raw = alert.get("containers")
    if raw is None:
        return []
    if isinstance(raw, str):
        try:
            raw = json.loads(raw or "[]")
        except ValueError:
            return []
    if not isinstance(raw, list):
        return []
    labels = [str(c).strip()[:64] for c in raw if str(c).strip()]

    files = [str(g.get("file") or "") for g in (alert.get("preview") or [])
             if isinstance(g, dict)]
    files += [str(h.get("file") or "") for h in (alert.get("evidence") or [])
              if isinstance(h, dict)]
    return legacy.enrich_containers(labels, files)


def format_alert(project_name: str, alert: dict, tz: ZoneInfo,
                 max_paths: int = PREVIEW_PATHS,
                 per_path: int = PREVIEW_EVENTS_PER_PATH,
                 max_events: int = PREVIEW_EVENTS_TOTAL) -> str:
    """One batch alert -> ONE Telegram message, never split.

    🛡 CENTRAL SECURITY ALERT · 📅 thời điểm
    ⚠️ Cảnh báo (câu cố định)
    📦 Dự án · 🖥 Môi trường/OS · 👤 User · 🏷 Hostname · 🌐 IP LAN · 🐳 Container
    🧩 Event logs (x events) — x = số event THẬT server nhận (dedup, chống hit ảo)
       Path 1: <file>  ->  blockquote các event đại diện, timeline in đậm
       Path 2: ...

    Envelope là BẤT BIẾN: Môi trường/OS/User/Hostname/IP luôn hiện đủ để biết
    server nào đang bị ảnh hưởng. Khi thiếu chỗ, CHỈ khối Event logs co lại:
      1. path/event nào vừa nguyên văn thì nhận nguyên văn
      2. event kế tiếp bị cắt tiền tố + "…" để lấp hết chỗ còn lại
      3. hết chỗ thì đóng bằng "… +N path / +M event"
    Không bao giờ sinh tin thứ hai, không bao giờ cắt mất dòng Môi trường/OS.
    """
    esc = _esc
    when = (_parse_ts(alert.get("ts_utc") or alert.get("ts") or alert.get("window_end"))
            or datetime.now(tz)).astimezone(tz)

    groups = _preview_groups(alert)
    total = event_total(alert, groups)

    # "User" is the OS account the monitor runs as — the account that would own
    # any dropped shell. "Hostname" is what the machine calls itself. Both come
    # from the device envelope, so a renamed box or a service account is visible
    # straight from the alert.
    # Một quy ước duy nhất cho giá trị thiếu: "không rõ" ở MỌI dòng.
    unknown = "không rõ"
    user = str(alert.get("user") or "").strip()[:64] or unknown
    hostname = (str(alert.get("hostname") or alert.get("host")
                    or alert.get("device") or "").strip()[:64] or unknown)
    lan_ip = str(alert.get("lan_ip") or "").strip()[:64] or unknown
    env = str(alert.get("env") or "").strip()[:32] or unknown
    os_name = str(alert.get("os") or "").strip()[:80] or unknown

    lines = [
        "🛡 <b>CENTRAL SECURITY ALERT</b>",
        f"📅 <i>{when:%d/%m/%Y} - {when:%H:%M}</i>",
        "",
        f"⚠️ <b>{ALERT_LABEL}:</b> {esc(_headline(alert))}",
        "",
        f"📦 <b>Dự án:</b> <code>{esc(project_name[:64])}</code>",
        f"🖥 <b>Môi trường / OS:</b> <b>[{esc(env)}]</b> <code>{esc(os_name)}</code>",
        f"👤 <b>User:</b> <code>{esc(user)}</code>",
        f"🏷 <b>Hostname:</b> <code>{esc(hostname)}</code>",
    ]

    # Container nguồn của alert (monitor aggregate từ field file của từng hit:
    # docker:<tên> / container:<tên>) — không có nghĩa alert từ chính host.
    containers = _container_list(alert)[:5]
    if containers:
        lines.append(f"🐳 <b>Container:</b> <code>{esc(', '.join(containers))}</code>")

    lines.append(f"🌐 <b>IP LAN:</b> <code>{esc(lan_ip)}</code>")

    header = f"🧩 <b>Event logs ({total} event{'' if total == 1 else 's'})</b>"
    blocks = group_by_path(groups, max_paths, per_path, max_events)

    if not blocks:
        # Không có preview[]: hoặc agent cũ (<= 1.4.2) hoặc ALERT_PREVIEW_MAX=0.
        # Chỉ nêu đúng con số đã biết chắc — tổng event của batch. Không bịa
        # "1 nhóm", không liệt kê mã rule (chi tiết ở GET /alerts/{id}).
        lines += ["", header]
        return "\n".join(lines)

    # Tổng số path/event THẬT để phần đuôi "… +N" nói đúng phần bị ẩn.
    all_paths = len({_path_of(g) for g in groups})
    hidden_paths = max(0, all_paths - len(blocks))
    shown_events = sum(len(b["events"]) for b in blocks)
    # Số event bị ẩn phải tính trên TỔNG event thật của batch, không phải trên số
    # nhóm preview: một batch 88 707 event chỉ mang 8 nhóm preview, nên
    # len(groups)-shown sẽ nói "+2 event" trong khi thực tế còn 88 200. Người
    # trực ca đọc con số đó sẽ đánh giá sai quy mô.
    hidden_events = max(0, max(total, len(groups)) - shown_events)

    def render(block_list: list[dict], tail: str) -> str:
        out = list(lines) + ["", header]
        for b in block_list:
            label = _path_line(b["path"]) or ""
            if not label:
                label = _source_line(b.get("source") or "")
            if label:
                out.append(label)
            out.append("<blockquote>" + "\n".join(
                _event_line(g) for g in b["events"]) + "</blockquote>")
        if tail:
            out.append(tail)
        return "\n".join(out)

    text = render(blocks, _tail(hidden_paths, hidden_events))
    if parsed_len(text) <= TG_LIMIT:
        return text

    # Quá 4096: bỏ dần event cuối cho tới khi vừa; event bị bỏ được tính vào đuôi.
    work = [{"path": b["path"], "events": list(b["events"])} for b in blocks]
    dropped = hidden_events
    while True:
        tail = _tail(hidden_paths, dropped)
        text = render(work, tail)
        if parsed_len(text) <= TG_LIMIT:
            return text
        # bỏ event cuối cùng còn lại
        while work and not work[-1]["events"]:
            work.pop()
            hidden_paths += 1
        if not work:
            # Ngay khối đầu cũng không vừa: cắt tiền tố của raw duy nhất.
            first = blocks[0]
            label = _path_line(first["path"]) or _source_line(first.get("source") or "")
            budget = TG_LIMIT - parsed_len("\n".join(
                lines + ["", header, label, "<blockquote></blockquote>"])) - 8
            cut = _fit_raw(first["events"][0]["raw"], max(0, budget))
            body = [f"<blockquote>{cut}</blockquote>"] if cut else []
            head2 = [h for h in (label,) if h]
            return "\n".join(lines + ["", header] + head2 + body)
        work[-1]["events"].pop()
        dropped += 1


class TelegramClient:
    """Gửi tin nhắn qua Bot API + giữ nhịp ≤1 tin/giây/chat."""

    def __init__(self, token: str) -> None:
        self.token = token
        self._http = httpx.AsyncClient(timeout=20)
        self._last_sent: dict[str, float] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    async def aclose(self) -> None:
        await self._http.aclose()

    async def send_message(self, chat_id: str, text: str) -> tuple[bool, str]:
        """Trả (thành công?, lỗi). Xử lý 429 (retry_after) tự động."""
        lock = self._locks.setdefault(chat_id, asyncio.Lock())
        async with lock:
            elapsed = asyncio.get_event_loop().time() - self._last_sent.get(chat_id, 0.0)
            if elapsed < 1.05:
                await asyncio.sleep(1.05 - elapsed)
            for attempt in (1, 2):
                try:
                    r = await self._http.post(
                        TG_API.format(token=self.token, method="sendMessage"),
                        data={"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                              "disable_web_page_preview": "true"},
                    )
                except httpx.HTTPError as e:
                    return False, f"network: {e}"
                if r.status_code == 429:
                    retry = float(r.json().get("parameters", {}).get("retry_after", 3))
                    await asyncio.sleep(min(retry, 15) + 0.5)
                    continue
                if r.status_code == 200:
                    self._last_sent[chat_id] = asyncio.get_event_loop().time()
                    return True, ""
                body = r.text[:200]
                if attempt == 2:
                    return False, f"telegram http {r.status_code}: {body}"
        return False, "telegram retries exhausted"


class PairingBot:
    """Polling bot: quản lý server theo CHAT ID (chat riêng hoặc group).

    Luồng chat-id: /id lấy Chat ID -> script pair nhập Chat ID -> ghép nối
    TỰ ĐỘNG (không /confirm — triển khai số lượng lớn không spam). Một chat
    ghép được NHIỀU server; /list xem tất cả; /unlink ngắt một dự án.
    """

    # Menu lệnh (nút ≡ / gõ "/"). Tên: lowercase a-z0-9_, tối đa 32 ký tự.
    BOT_COMMANDS = [
        ("start", "Bắt đầu"),
        ("id", "Lấy Chat ID của chat này"),
        ("list", "Dự án & số thiết bị"),
        ("unlink", "Ngắt một dự án khỏi chat này"),
        ("help", "Trợ giúp"),
    ]
    # /start — đúng một câu, không kèm menu/hướng dẫn.
    START_TEXT = (
        "👋 Central Alert Bot — cảnh báo an ninh tấn công khai thác lỗ hổng "
        "php2Shell từ các server của bạn ngay trên Telegram."
    )
    # /help — ngắn gọn: danh sách lệnh + 1 dòng ghép nối.
    HELP_TEXT = (
        "🤖 <b>Central Alert Bot — Trợ giúp</b>\n"
        "• <code>/id</code> — lấy Chat ID của chat này\n"
        "• <code>/list</code> — dự án &amp; số thiết bị\n"
        "• <code>/unlink &lt;tên&gt;</code> — ngắt một dự án\n"
        "• <code>/help</code> — trợ giúp \n\n"
    )
    # /list khi chat chưa ghép dự án nào — không kèm hướng dẫn.
    LIST_EMPTY_TEXT = "📭 Chưa có dự án nào được ghép với chat này."
    BOT_DESCRIPTION = (
        "🛡 Central Alert Bot — nhận cảnh báo an ninh (php2shell-monitor) từ các"
        " server của bạn ngay trên Telegram.\n\n"
        "Ghép nối: /id lấy Chat ID → nhập vào script pair trên server — tự động"
        " ghép ngay, không cần xác nhận. Chat riêng hoặc group đều được; /list"
        " xem tất cả, /unlink để ngắt."
    )
    BOT_SHORT_DESCRIPTION = ("Cảnh báo an ninh server → Telegram."
                             " /id lấy Chat ID rồi chạy pair trên server.")

    def __init__(self, cfg: Config, tg: TelegramClient, db_path: str) -> None:
        self.cfg = cfg
        self.tg = tg
        self.db_path = db_path
        self.guard = AttemptGuard(cfg.bot_attempts_limit, cfg.bot_attempts_window_sec,
                                  cfg.bot_mute_sec)
        self._me: str = ""

    async def _api(self, method: str, **kwargs) -> dict:
        r = await self.tg._http.post(TG_API.format(token=self.cfg.bot_token, method=method),
                                     **kwargs)
        r.raise_for_status()
        return r.json()

    async def start(self) -> None:
        me = await self._api("getMe")
        self._me = me["result"].get("username", "")
        self.tg.bot_username = self._me  # routes dùng để trả bot handle cho agent
        log.info("bot @%s polling started", self._me)
        # Đăng ký menu lệnh (nút ≡ / gõ "/"): idempotent, lỗi không chặn polling
        for method, payload in (
            ("setMyCommands", {"commands": [
                {"command": c, "description": d} for c, d in self.BOT_COMMANDS]}),
            ("setMyDescription", {"description": self.BOT_DESCRIPTION}),
            ("setMyShortDescription", {"short_description": self.BOT_SHORT_DESCRIPTION}),
        ):
            try:
                await self._api(method, json=payload)
            except Exception:  # noqa: BLE001
                log.warning("bot %s thất bại (menu/mô tả không cập nhật)", method)

    async def run(self) -> None:
        offset = 0
        while True:
            try:
                if not self._me:
                    await self.start()
                data = await self.tg._http.get(
                    TG_API.format(token=self.cfg.bot_token, method="getUpdates"),
                    params={"offset": offset, "timeout": 25},
                    timeout=30,
                )
                data.raise_for_status()
                for upd in data.json().get("result", []):
                    offset = max(offset, upd["update_id"] + 1)
                    try:
                        await self.handle_update(upd)
                    except Exception:  # noqa: BLE001 — không làm chết vòng polling
                        log.exception("xử lý update %s lỗi", upd.get("update_id"))
            except Exception:  # noqa: BLE001 — cả lỗi getMe/getUpdates: chờ rồi thử lại
                log.warning("polling/getMe lỗi (token sai hoặc mất mạng?), thử lại sau 10s")
                await asyncio.sleep(10)

    async def handle_update(self, upd: dict) -> None:
        msg = upd.get("message") or upd.get("edited_message") or {}
        chat_id = str((msg.get("chat") or {}).get("id") or "")
        text = str(msg.get("text") or "").strip()
        if not chat_id:
            return
        if self.guard.is_muted(chat_id):
            return

        # Lệnh (chuẩn hoá: bỏ '/', bỏ @botname, chữ thường)
        cmd = text.split()[0].lstrip("/").split("@")[0].lower() if text else ""
        if CODE_RE.search(text):
            await self.tg.send_message(
                chat_id,
                "⌛ Mã <code>SEC-&lt;UUID&gt;</code> đã ngừng sử dụng.\n"
                "Ghép nối bây giờ qua Chat ID: <code>/id</code> để lấy Chat ID →"
                " nhập vào script <code>pair</code> trên server — ghép nối tự"
                " động, không cần xác nhận gì thêm.",
            )
        elif cmd == "start":
            await self._cmd_help(chat_id, welcome=True)
        elif cmd == "help":
            await self._cmd_help(chat_id)
        elif cmd == "id":
            await self._cmd_id(chat_id, msg)
        elif cmd == "confirm":
            await self._cmd_confirm(chat_id, msg)
        elif cmd == "unlink":
            await self._cmd_unlink(chat_id, msg)
        elif cmd in ("list", "ids", "servers"):
            await self._cmd_list(chat_id)
        else:
            await self._cmd_help(chat_id)

    async def _cmd_id(self, chat_id: str, msg: dict) -> None:
        """In Chat ID để user copy vào script pair (chat riêng hoặc group)."""
        chat = msg.get("chat") or {}
        kind = "nhóm" if chat.get("type") in ("group", "supergroup") else "riêng tư"
        await self.tg.send_message(
            chat_id,
            f"🆔 <b>Chat ID: <code>{html.escape(chat_id)}</code></b>\n"
            f"📎 Loại: {kind}\n"
            + ("⚠️ Trong nhóm, bot cần được thêm làm <b>thành viên</b> để gửi"
               " cảnh báo vào đây." if kind == "nhóm" else ""),
        )

    async def _cmd_confirm(self, chat_id: str, msg: dict) -> None:
        """Đồng ý mọi yêu cầu ghép nối đang chờ của CHÍNH chat này."""
        who = str((msg.get("from") or {}).get("first_name") or "ai đó")
        n = len(db.projects_by_chat(self.db_path, chat_id))
        await self.tg.send_message(
            chat_id,
            "ℹ️ <b>Ghép nối giờ đã TỰ ĐỘNG — không cần /confirm nữa.</b>\n"
            "Chạy <code>pair</code> trên server với Chat ID của chat này là ghép"
            " xong ngay (server tự nhận API key).\n\n"
            f"📎 Chat này đang quản lý <b>{n} dự án</b> — <code>/list</code> để xem,"
            " <code>/unlink &lt;tên dự án&gt;</code> để ngắt một dự án.",
        )
        log.info("/confirm trong chat=%s (bởi %s) — ghép nối đã tự động", chat_id, who)

    async def _cmd_unlink(self, chat_id: str, msg: dict) -> None:
        """/unlink <tên dự án> — ngắt dự án khỏi chat: alert dừng gửi, lịch sử giữ."""
        who = str((msg.get("from") or {}).get("first_name") or "ai đó")
        parts = (msg.get("text") or "").split(maxsplit=1)
        name = parts[1].strip() if len(parts) > 1 else ""
        if not name:
            rows = db.projects_by_chat(self.db_path, chat_id)
            if not rows:
                await self.tg.send_message(
                    chat_id,
                    "Chat này chưa ghép dự án nào nên không có gì để ngắt.\n"
                    "Muốn bắt đầu: <code>/id</code> lấy Chat ID → chạy <code>pair</code>"
                    " trên server.",
                )
                return
            names = " · ".join(f"<code>/unlink {html.escape(r['project_name'])}</code>"
                               for r in rows)
            await self.tg.send_message(
                chat_id,
                "Cách dùng: <code>/unlink &lt;tên dự án&gt;</code>\n"
                f"Các dự án đang ghép với chat này: {names}",
            )
            return
        res = db.unlink_project(self.db_path, name, chat_id)
        if res is None:
            await self.tg.send_message(
                chat_id,
                f"❌ Không tìm thấy dự án <b>{html.escape(name)}</b> đang ghép với"
                " chat này (xem <code>/list</code>; tên phải viết đúng).",
            )
            return
        log.info("unlink: project=%s chat=%s (bởi %s)", name, chat_id, who)
        await self.tg.send_message(
            chat_id,
            f"🚫 <b>Đã ngắt dự án {html.escape(name)}</b>\n"
            "Alert từ dự án này sẽ KHÔNG còn gửi vào chat, mọi API key của dự"
            " án đã bị thu hồi (lịch sử alert vẫn được lưu trên server trung"
            " tâm).\n"
            "Muốn ghép lại: trên máy dự án chạy lại đúng lệnh deploy\n"
            f"<code>php2shell-monitor.sh --project {html.escape(name)}"
            " --chatid &lt;chat-id&gt;</code>\n"
            "— script tự phát hiện key đã chết và ghép nối lại, không cần"
            " gõ thêm gì.",
        )

    # ------------------------------------------------------------- lệnh

    async def _cmd_help(self, chat_id: str, welcome: bool = False) -> None:
        # /start: đúng một dòng giới thiệu, không kèm hướng dẫn.
        if welcome:
            await self.tg.send_message(chat_id, self.START_TEXT)
            return
        await self.tg.send_message(chat_id, self.HELP_TEXT)

    async def _cmd_list(self, chat_id: str) -> None:
        """Dự án đang quản lý + số thiết bị từng dự án. Không kèm hướng dẫn.

        Nghiệp vụ: một dự án khả dụng luôn có >= 1 thiết bị; dự án 0 thiết bị
        được đánh dấu "chưa khả dụng" thay vì ẩn đi.
        """
        rows = db.projects_by_chat(self.db_path, chat_id)
        if not rows:
            await self.tg.send_message(chat_id, self.LIST_EMPTY_TEXT)
            return

        counts = [int(r["device_count"]) for r in rows]
        active = sum(1 for c in counts if c)
        lines = [
            "🗂 <b>Dự án đang quản lý</b>",
            f"📦 Dự án: <b>{len(rows)}</b> (khả dụng <b>{active}</b>)"
            f" · Thiết bị: <b>{sum(counts)}</b>",
            "",
        ]
        for i, (r, n_dev) in enumerate(zip(rows, counts), 1):
            lines.append(f"{i}. <b>{html.escape(r['project_name'])}</b>")
            lines.append(f"    🖥 Số thiết bị: <b>{n_dev}</b>"
                         + ("" if n_dev else " — chưa khả dụng"))
        await self.tg.send_message(chat_id, "\n".join(lines))
