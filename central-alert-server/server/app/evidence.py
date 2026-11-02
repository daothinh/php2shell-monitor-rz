"""Ingest: store one batch alert per device + mirror raw hits to disk."""
import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import db
from .config import Config

log = logging.getLogger("alert-server.evidence")


def device_label(alert: dict) -> str:
    """Device folder name: IP-LAN_<lan_ip>_<hostname>.

    The OS account is deliberately NOT part of the path. The monitor runs as
    whatever account installed it, and that can change (root today, a service
    account after a hardening pass) without the machine being a different
    machine. Including it split one box's evidence across two folders. The user
    is still recorded on every hit and shown in the Telegram alert.
    """
    ip = str(alert.get("lan_ip") or "").strip() or "unknown"
    host = (str(alert.get("hostname") or "").strip()
            or str(alert.get("host") or alert.get("device") or "").strip()
            or "unknown")
    return db.slug(f"IP-LAN_{ip}_{host}")


def evidence_path(cfg: Config, project: str, label: str, batch_id: str) -> Path:
    """<root>/<project>/IP-LAN_<ip>_<hostname>/<batch>.jsonl — one file per batch.

    batch_id already carries the UTC timestamp (YYYYMMDDTHHMMSSZ), so no day
    folder is needed.
    """
    return Path(cfg.evidence_root) / db.slug(project) / label / f"{db.slug(batch_id)}.jsonl"


def write_evidence(cfg: Config, project: str, alert: dict) -> str:
    """Persist every raw hit of this alert. Returns the path ("" when none)."""
    hits = alert.get("evidence") or []
    if not isinstance(hits, list) or not hits:
        return ""
    path = evidence_path(cfg, project, device_label(alert),
                         str(alert.get("batch_id") or "batch"))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".jsonl.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        for h in hits:
            if isinstance(h, dict):
                f.write(json.dumps(h, ensure_ascii=False) + "\n")
    tmp.replace(path)
    return str(path)


def normalize(alert: dict, default_host: str = "", default_lan_ip: str = "",
              default_user: str = "", default_os: str = "",
              default_env: str = "") -> dict:
    """Coerce an incoming alert into the batch-alert shape the store expects.

    The monitor already sends this shape; the fallbacks keep hand-written or
    older payloads usable (single rule_id, message, src_ip...).
    """
    a = dict(alert or {})
    a.setdefault("severity", "INFO")
    a["severity"] = str(a.get("severity") or "INFO").upper()
    if not a.get("batch_id"):
        a["batch_id"] = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    hits = a.get("evidence")
    if not isinstance(hits, list) or not hits:
        # legacy single-alert payload -> synthesize one hit from its own fields
        raw = str(a.get("message") or a.get("notes") or "")
        hits = [{
            "rule_id": a.get("rule_id"),
            "severity": a["severity"],
            "source": a.get("source") or a.get("tier") or "",
            "file": a.get("file") or "",
            "line": a.get("line") or 0,
            "ip": a.get("src_ip") or "",
            "method": a.get("method") or "",
            "uri": a.get("uri") or "",
            "status": a.get("status") or "",
            "ua": a.get("ua") or "",
            "pid": a.get("pid") or "",
            "raw": raw,
            "ts_utc": a.get("ts_utc") or a.get("ts") or "",
        }]
    a["evidence"] = hits
    a["hits"] = int(a.get("hits") or len(hits))
    if not a.get("rules"):
        seen: dict[str, int] = {}
        for h in hits:
            rid = str((h or {}).get("rule_id") or "")
            if rid:
                seen[rid] = seen.get(rid, 0) + 1
        a["rules"] = [{"rule_id": k, "hits": v} for k, v in sorted(seen.items())]
    a["host"] = a.get("host") or default_host
    a["device"] = a.get("device") or a.get("host") or default_host or "unknown"
    a["lan_ip"] = a.get("lan_ip") or default_lan_ip
    a["user"] = str(a.get("user") or default_user or "")
    a["os"] = str(a.get("os") or default_os or "")
    a["env"] = str(a.get("env") or default_env or "")

    # preview: các nhóm event monitor gửi kèm để render tin Telegram ngay.
    # Phải giữ qua normalize — nó là nguồn duy nhất của raw line lúc gửi tin,
    # vì file evidence được upload SAU alert (xem central.sh upload_evidence).
    # Không suy ra từ evidence[]: evidence[] rỗng khi MAX_EVIDENCE_INLINE=0.
    prev = a.get("preview")
    a["preview"] = [g for g in prev if isinstance(g, dict)] if isinstance(prev, list) else []
    a["preview_meta"] = str(a.get("preview_meta") or "")
    return a


def device_of(alert: dict, body_host: str) -> str:
    return str(alert.get("device") or alert.get("host") or body_host or "unknown")


__all__: list[Any] = [
    "device_label", "evidence_path", "write_evidence", "normalize", "device_of",
]
