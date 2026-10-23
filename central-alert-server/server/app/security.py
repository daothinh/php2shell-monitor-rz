"""Sinh khóa, mã pairing, rate-limit trong bộ nhớ."""
import hashlib
import threading
import time
import uuid
from collections import defaultdict, deque
from typing import Optional
import secrets


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def gen_api_key() -> str:
    """API key 43 ký tự URL-safe (~256 bit entropy)."""
    return "p2s_" + secrets.token_urlsafe(32)


def gen_pairing_code() -> str:
    """Mã ghép nối dạng UUID (SEC-<uuid4>, chữ hoa): 122-bit entropy, không thể dò tăng dần."""
    return f"SEC-{uuid.uuid4()!s}".upper()


class RateLimiter:
    """Cửa sổ trượt trong bộ nhớ: allow(key) -> bool."""

    def __init__(self) -> None:
        self._events: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str, limit: int, window_sec: float) -> tuple[bool, Optional[int]]:
        """Trả (cho phép?, retry_after_giây)."""
        now = time.monotonic()
        with self._lock:
            q = self._events[key]
            while q and now - q[0] > window_sec:
                q.popleft()
            if len(q) >= limit:
                retry = int(window_sec - (now - q[0])) + 1
                return False, max(retry, 1)
            q.append(now)
            return True, None


class AttemptGuard:
    """Chống dò mã pairing qua bot: sai N lần trong cửa sổ -> khoá tạm."""

    def __init__(self, limit: int, window_sec: int, mute_sec: int) -> None:
        self.limit = limit
        self.window_sec = window_sec
        self.mute_sec = mute_sec
        self._fails: dict[str, deque[float]] = defaultdict(deque)
        self._muted: dict[str, float] = {}
        self._lock = threading.Lock()

    def is_muted(self, key: str) -> bool:
        with self._lock:
            until = self._muted.get(key, 0.0)
            if until and time.monotonic() < until:
                return True
            self._muted.pop(key, None)
            return False

    def record_fail(self, key: str) -> None:
        now = time.monotonic()
        with self._lock:
            q = self._fails[key]
            q.append(now)
            while q and now - q[0] > self.window_sec:
                q.popleft()
            if len(q) >= self.limit:
                self._muted[key] = now + self.mute_sec
                q.clear()

    def record_success(self, key: str) -> None:
        with self._lock:
            self._fails.pop(key, None)
