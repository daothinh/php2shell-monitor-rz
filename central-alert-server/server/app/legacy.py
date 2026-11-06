"""Chuẩn hoá dữ liệu do monitor 1.4.2 gửi lên.

VÌ SAO CẦN
Monitor 1.4.2 đẩy vào field `file` những giá trị KHÔNG phải đường dẫn:

    docker:<tên>:<cid12>              # docker_logs.sh  -> mất đường dẫn host
    container:<tên>:<cid12>           # container_accesslog.sh -> mất path trong container
    journalctl -k                     # kernel.sh -> một câu lệnh, không phải file

Server không thể "sửa" monitor đã cài trên máy khách, nhưng nó biết đủ để dựng
lại đường dẫn THẬT mà bản mới (>= 1.4.13) sẽ ghi. Mọi giá trị dưới đây đều là
đường dẫn tuyệt đối, copy-paste được, và trỏ đúng một file trên host:

    docker:<tên>:<cid12>       -> /var/lib/docker/containers/<cid12>*/<cid12>*-json.log
    container:<tên>:<cid12>    -> (cùng file json log — 1.4.2 không ghi path bên trong)
    journalctl -k              -> /var/log/journal/*/system.journal

Vì sao dùng GLOB (`*`) chứ không phải đường dẫn tuyệt đối đầy đủ: payload chỉ
mang 12 ký tự đầu của container id và không mang machine-id. Glob giữ đúng tính
chất "đường dẫn tuyệt đối tới một file" và mở được ngay bằng `ls`, trong khi bịa
một đường dẫn đầy đủ sẽ trỏ vào file không tồn tại.

Nguồn nào KHÔNG suy ra được đường dẫn thì để rỗng — tầng hiển thị in
`Nguồn: <source>` thay vì đội lốt nhãn "Path". Không đoán.
"""
import re
from typing import Optional

# /var/lib/docker/containers/<cid>/<cid>-json.log — dạng ĐẦY ĐỦ của bản mới.
_DOCKER_FULL = re.compile(
    r"^docker:(?P<name>[^:]+):(?P<cid12>[0-9a-f]{12}):(?P<path>/\S+)$")
# docker:<tên> hoặc docker:<tên>:<cid12> — dạng 1.4.2.
_DOCKER_LEGACY = re.compile(r"^docker:(?P<name>[^:]+)(?::(?P<cid12>[0-9a-f]{12}))?$")
# container:<tên>:<đường dẫn tuyệt đối> — dạng mới, hợp lệ.
_CONTAINER_NEW = re.compile(r"^container:(?P<name>[^:]+):(?P<path>/\S+)$")
# container:<tên>:<cid12> — dạng 1.4.2 của container_accesslog (mất path).
_CONTAINER_LEGACY = re.compile(r"^container:(?P<name>[^:]+):(?P<cid12>[0-9a-f]{12})$")

# `journalctl` với mọi tham số: -k, --since ..., -u unit, --file ...
_JOURNALCTL = re.compile(r"^journalctl(\s|$)")

DOCKER_LOG_DIR = "/var/lib/docker/containers"
# journald: bản persistent trước, bản volatile (mất sau reboot) sau.
JOURNAL_PERSISTENT = "/var/log/journal/*/system.journal"
JOURNAL_VOLATILE = "/run/log/journal/*/system.journal"


def docker_log_glob(cid12: str) -> str:
    """Đường dẫn tuyệt đối (glob) tới file json log của container trên host."""
    return f"{DOCKER_LOG_DIR}/{cid12}*/{cid12}*-json.log"


def resolve_file(raw: Optional[str]) -> str:
    """Chuẩn hoá field `file` của một hit. Trả "" khi không suy ra được đường dẫn.

    Idempotent: đường dẫn tuyệt đối và các dạng mới được giữ nguyên.
    """
    p = (raw or "").strip()
    if not p or " " in p and not _JOURNALCTL.match(p):
        # có khoảng trắng = câu mô tả, trừ journalctl (xử lý ngay dưới)
        if not _JOURNALCTL.match(p):
            return p if p.startswith("/") else ""
    if not p:
        return ""

    if p.startswith("/"):
        return p                       # đã là đường dẫn tuyệt đối

    m = _DOCKER_FULL.match(p)
    if m:
        return m.group("path")         # bản mới: đã có path đầy đủ

    m = _DOCKER_LEGACY.match(p)
    if m:
        cid = m.group("cid12")
        if cid:
            return docker_log_glob(cid)
        return ""                      # chỉ có tên: không suy ra được

    m = _CONTAINER_NEW.match(p)
    if m:
        return f"container:{m.group('name')}:{m.group('path')}"

    m = _CONTAINER_LEGACY.match(p)
    if m:
        # 1.4.2 đọc access log BÊN TRONG container nhưng chỉ gửi cid12. Trên host,
        # mọi thứ container ghi ra đều nằm ở json log — đó là file mở được, và
        # là nơi duy nhất còn dấu vết khi path bên trong không được ghi lại.
        return docker_log_glob(m.group("cid12"))

    if _JOURNALCTL.match(p):
        return JOURNAL_PERSISTENT

    return ""                          # câu mô tả khác: không phải đường dẫn


def cid12_of(raw: Optional[str]) -> str:
    """Bóc cid12 từ một giá trị `file` bất kỳ (dạng cũ hoặc mới)."""
    p = (raw or "").strip()
    for rx in (_DOCKER_FULL, _DOCKER_LEGACY, _CONTAINER_LEGACY):
        m = rx.match(p)
        if m and m.groupdict().get("cid12"):
            return m.group("cid12")
    m = _CONTAINER_NEW.match(p)
    if m:
        return ""
    return ""


# Tên container 1.4.2 gửi có thể kèm cid12 trong ngoặc: "drill-dwva (33ae17b45385)"
_NAME_WITH_CID = re.compile(r"^(?P<name>.+?)\s*\((?P<cid12>[0-9a-f]{12})\)$")


def normalise_container(label: str, known: Optional[dict] = None) -> str:
    """Chuẩn hoá một phần tử `containers[]` thành "<tên> (<cid12>)" khi biết cid.

    Vì sao: operator cần phân biệt hai container TRÙNG TÊN trên hai máy khác
    nhau, nên cid12 là thông tin bắt buộc. 1.4.2 có lúc gửi tên trần
    ("drill-dwva"), có lúc gửi "tên (cid12)". `known` là map tên -> cid12 dựng
    từ chính các hit của alert đó (field `file`), nên không phải đoán.
    """
    s = (label or "").strip()
    if not s:
        return ""
    m = _NAME_WITH_CID.match(s)
    if m:
        return f"{m.group('name').strip()} ({m.group('cid12')})"
    cid = (known or {}).get(s, "")
    return f"{s} ({cid})" if cid else s


def enrich_containers(labels: list, files: list) -> list:
    """Thêm cid12 cho các phần tử `containers[]` còn thiếu, dựa trên field `file`.

    Không bịa: chỉ dùng cid12 thật đã thấy trong chính alert đó.
    """
    known: dict = {}
    for f in files or []:
        cid = cid12_of(f)
        if not cid:
            continue
        name = _container_name_of(f)
        if name and name not in known:
            known[name] = cid
    out, seen = [], set()
    for label in labels or []:
        # 1.4.2 có thể gửi "name (cid)" -> tách tên để tra map
        base = label
        m = _NAME_WITH_CID.match((label or "").strip())
        if m:
            base = m.group("name").strip()
        val = normalise_container(label, known)
        if val and val not in seen:
            seen.add(val)
            out.append(val)
    return out


def _container_name_of(raw: str) -> str:
    p = (raw or "").strip()
    for rx in (_DOCKER_FULL, _DOCKER_LEGACY, _CONTAINER_NEW, _CONTAINER_LEGACY):
        m = rx.match(p)
        if m:
            return m.group("name")
    return ""
