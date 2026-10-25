"""One-shot data migrations, safe to run on every start.

Evidence folders used to be named IP-LAN_<ip>_<hostname>_<user>. The account
the monitor runs as is not part of a machine's identity, so the same box could
end up with two folders (root before a hardening pass, www-data after). Folders
are now IP-LAN_<ip>_<hostname>; this module merges the old ones in place.

Merging never overwrites: batch ids are unique per device, so a collision means
the same batch was written twice, and the existing file is kept.
"""
import logging
import re
import shutil
from pathlib import Path

log = logging.getLogger("alert-server.migrate")

# Old layout: IP-LAN_<ip>_<hostname>_<user>; new: IP-LAN_<ip>_<hostname>.
#
# Telling them apart by shape alone is impossible: a hostname may contain "_"
# ("web_01_prod"), so IP-LAN_10.0.0.5_web_01_prod is a valid NEW name and also
# parses as OLD with host="web_01" user="prod". Guessing by regex re-merged an
# already-migrated folder on every start, each pass eating one "_" segment.
#
# So the layout is recorded explicitly. The marker is written after a successful
# pass; when it exists this module does nothing at all.
_MARKER = ".evidence-layout-2"

# Used only on the very first pass, when the marker does not exist yet. It
# requires a trailing component that looks like an OS account, which new-style
# names cannot produce because they end with the hostname.
_IPV4 = r"(?:\d{1,3}\.){3}\d{1,3}"
_OLD = re.compile(
    rf"^IP-LAN_(?P<ip>{_IPV4}|unknown)_(?P<host>.+?)_(?P<user>"
    r"root|www-data|nobody|apache|nginx|php-fpm|daemon|ubuntu|admin|ec2-user|unknown"
    r")$"
)


def _split(name: str):
    """(ip, host, user) for an old-style folder, None when already new-style."""
    m = _OLD.match(name)
    if not m:
        return None
    return m.group("ip"), m.group("host"), m.group("user")


def merge_user_folders(root: str | Path) -> list[tuple[str, str, int]]:
    """Merge <project>/IP-LAN_<ip>_<host>_<user> into IP-LAN_<ip>_<host>.

    Returns [(old_relative, new_relative, files_moved)] for every folder merged.
    Idempotent: once merged the old folder is gone, so a second run is a no-op.
    """
    base = Path(root)
    if not base.is_dir():
        return []
    if (base / _MARKER).exists():
        return []   # already on layout 2: never guess again

    done: list[tuple[str, str, int]] = []
    for project_dir in sorted(p for p in base.iterdir() if p.is_dir()):
        for old_dir in sorted(p for p in project_dir.iterdir() if p.is_dir()):
            parts = _split(old_dir.name)
            if not parts:
                continue
            ip, host, _user = parts
            new_dir = project_dir / f"IP-LAN_{ip}_{host}"
            moved = 0
            for src in sorted(old_dir.iterdir()):
                if not src.is_file():
                    continue
                dst = new_dir / src.name
                if dst.exists():
                    # Same batch already present: keep the existing copy, drop
                    # the duplicate so the old folder can be removed.
                    src.unlink()
                    continue
                new_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(dst))
                moved += 1
            # Only remove the old folder when nothing is left inside.
            try:
                old_dir.rmdir()
            except OSError:
                log.warning("không xoá được %s (còn file lạ)", old_dir)
                continue
            done.append((str(old_dir.relative_to(base)),
                         str(new_dir.relative_to(base)), moved))
            log.info("gộp evidence %s -> %s (%d file)",
                     old_dir.name, new_dir.name, moved)

    try:
        (base / _MARKER).write_text("2\n", encoding="utf-8")
    except OSError as exc:
        log.warning("không ghi được marker %s: %s", _MARKER, exc)
    return done
