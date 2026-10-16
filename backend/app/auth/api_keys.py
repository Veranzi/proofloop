"""API keys for other systems: ``Authorization: Bearer pf_live_<32 chars>``.

Only a SHA-256 hash and a 12-character display prefix are stored. The full
key is shown once, when it is created (Docs/Integrations_API_Contract.md §1).
"""

import hashlib
import secrets
import string
import threading
import time
from collections import deque
from datetime import UTC, datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.db.models import ApiKey
from app.errors import ApiError, unauthorized

KEY_PREFIX = "pf_live_"
_ALPHABET = string.ascii_letters + string.digits
RATE_LIMIT_PER_MINUTE = 600
_LAST_USED_EVERY = timedelta(minutes=1)


def generate_key() -> str:
    return KEY_PREFIX + "".join(secrets.choice(_ALPHABET) for _ in range(32))


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def display_prefix(key: str) -> str:
    return key[:12]


def is_api_key(token: str) -> bool:
    return token.startswith(KEY_PREFIX)


class _RateLimiter:
    """Sliding one-minute window per key, per instance.

    Cloud Run runs several instances, so the real ceiling is this limit times
    the instance count. Move to a shared store if that ever matters.
    """

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, key_id: str) -> None:
        now = time.monotonic()
        with self._lock:
            hits = self._hits.setdefault(key_id, deque())
            while hits and now - hits[0] >= 60:
                hits.popleft()
            if len(hits) >= self.limit:
                retry_after = max(1, int(60 - (now - hits[0])) + 1)
                raise ApiError(
                    429,
                    "rate_limited",
                    "Too many requests for this API key.",
                    headers={"Retry-After": str(retry_after)},
                )
            hits.append(now)

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


rate_limiter = _RateLimiter(RATE_LIMIT_PER_MINUTE)


def authenticate_key(db: Session, token: str) -> ApiKey:
    key = db.scalar(select(ApiKey).where(ApiKey.key_hash == hash_key(token)))
    if key is None or key.revoked_at is not None:
        raise unauthorized("Invalid API key.")
    rate_limiter.check(key.id)
    _touch_last_used(db, key)
    return key


def _touch_last_used(db: Session, key: ApiKey) -> None:
    """At most one write per key per minute, so busy keys don't cost a write each."""
    now = datetime.now(UTC)
    if key.last_used_at is not None and now - key.last_used_at < _LAST_USED_EVERY:
        return
    db.execute(
        update(ApiKey)
        .where(ApiKey.id == key.id)
        .where((ApiKey.last_used_at.is_(None)) | (ApiKey.last_used_at < now - _LAST_USED_EVERY))
        .values(last_used_at=now)
    )
    db.commit()
    key.last_used_at = now
