"""Object storage behind one small interface.

- ``GcsStorage``: private Cloud Storage bucket with V4 signed URLs (Cloud Run).
- ``LocalStorage``: files on disk; upload and view links point at this API and
  are HMAC-signed. Only mounted when PRUFLO_ENV is local or test.

Signed URLs are never logged.
"""

import base64
import hashlib
import hmac
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Protocol
from urllib.parse import quote

from app.config import get_settings


@dataclass(frozen=True)
class SignedRequest:
    url: str
    method: str
    expires_at: datetime
    headers: dict[str, str] = field(default_factory=dict)  # the client must send these


@dataclass(frozen=True)
class ObjectInfo:
    size: int
    content_type: str | None


class Storage(Protocol):
    def upload_request(self, key: str, content_type: str, max_bytes: int) -> SignedRequest: ...
    def view_url(self, key: str, file_name: str, content_type: str) -> SignedRequest: ...
    def stat(self, key: str) -> ObjectInfo | None: ...
    def read(self, key: str) -> bytes: ...
    def write(self, key: str, data: bytes, content_type: str) -> None: ...


def _expiry() -> tuple[timedelta, datetime]:
    ttl = timedelta(minutes=get_settings().signed_url_minutes)
    return ttl, datetime.now(UTC) + ttl


def _disposition(file_name: str, inline: bool = True) -> str:
    kind = "inline" if inline else "attachment"
    return f"{kind}; filename*=UTF-8''{quote(file_name)}"


class GcsStorage:
    def __init__(self, bucket: str) -> None:
        from google.cloud.storage import Client

        self._client = Client(project=get_settings().gcp_project)
        self._bucket = self._client.bucket(bucket)

    def _signing_kwargs(self) -> dict[str, object]:
        # On Cloud Run there's no key file: sign through the IAM signBlob API
        # using the service account's own access token.
        import google.auth
        import google.auth.transport.requests

        credentials, _ = google.auth.default()
        credentials.refresh(google.auth.transport.requests.Request())  # type: ignore[no-untyped-call]
        email = getattr(credentials, "service_account_email", None)
        if email:
            return {"service_account_email": email, "access_token": credentials.token}
        return {"credentials": credentials}

    def upload_request(self, key: str, content_type: str, max_bytes: int) -> SignedRequest:
        ttl, expires_at = _expiry()
        headers = {"Content-Type": content_type, "x-goog-content-length-range": f"0,{max_bytes}"}
        url = self._bucket.blob(key).generate_signed_url(
            version="v4", expiration=ttl, method="PUT", headers=headers, **self._signing_kwargs()
        )
        return SignedRequest(url=url, method="PUT", expires_at=expires_at, headers=headers)

    def view_url(self, key: str, file_name: str, content_type: str) -> SignedRequest:
        ttl, expires_at = _expiry()
        url = self._bucket.blob(key).generate_signed_url(
            version="v4",
            expiration=ttl,
            method="GET",
            response_disposition=_disposition(file_name),
            response_type=content_type,
            **self._signing_kwargs(),
        )
        return SignedRequest(url=url, method="GET", expires_at=expires_at)

    def stat(self, key: str) -> ObjectInfo | None:
        blob = self._bucket.get_blob(key)
        if blob is None:
            return None
        return ObjectInfo(size=int(blob.size or 0), content_type=blob.content_type)

    def read(self, key: str) -> bytes:
        return bytes(self._bucket.blob(key).download_as_bytes())

    def write(self, key: str, data: bytes, content_type: str) -> None:
        self._bucket.blob(key).upload_from_string(data, content_type=content_type)


class LocalStorage:
    def __init__(self, root: str, signing_key: str, base_url: str) -> None:
        self.root = Path(root).resolve()
        self._key = signing_key.encode()
        self._base = base_url.rstrip("/")

    def path(self, key: str) -> Path:
        target = (self.root / key).resolve()
        if not target.is_relative_to(self.root):
            raise ValueError("object key escapes the storage root")
        return target

    def sign(self, method: str, key: str, expires: int, extra: str = "") -> str:
        message = f"{method}\n{key}\n{expires}\n{extra}".encode()
        digest = hmac.new(self._key, message, hashlib.sha256).digest()
        return base64.urlsafe_b64encode(digest).decode().rstrip("=")

    def verify(self, method: str, key: str, expires: int, signature: str, extra: str = "") -> bool:
        if expires < time.time():
            return False
        return hmac.compare_digest(self.sign(method, key, expires, extra), signature)

    def _url(self, method: str, key: str, extra: str = "") -> tuple[str, datetime]:
        _, expires_at = _expiry()
        expires = int(expires_at.timestamp())
        sig = self.sign(method, key, expires, extra)
        return (
            f"{self._base}/v1/_local/objects/{quote(key)}?expires={expires}&sig={sig}",
            expires_at,
        )

    def upload_request(self, key: str, content_type: str, max_bytes: int) -> SignedRequest:
        url, expires_at = self._url("PUT", key, f"{content_type}\n{max_bytes}")
        url += f"&max={max_bytes}&ct={quote(content_type)}"
        return SignedRequest(url, "PUT", expires_at, headers={"Content-Type": content_type})

    def view_url(self, key: str, file_name: str, content_type: str) -> SignedRequest:
        url, expires_at = self._url("GET", key)
        return SignedRequest(url, "GET", expires_at)

    def stat(self, key: str) -> ObjectInfo | None:
        target = self.path(key)
        if not target.is_file():
            return None
        meta = target.with_name(target.name + ".type")
        content_type = meta.read_text() if meta.is_file() else None
        return ObjectInfo(size=target.stat().st_size, content_type=content_type)

    def read(self, key: str) -> bytes:
        return self.path(key).read_bytes()

    def write(self, key: str, data: bytes, content_type: str) -> None:
        target = self.path(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.with_name(target.name + ".type").write_text(content_type)


@lru_cache
def _default_storage() -> Storage:
    settings = get_settings()
    if settings.storage_backend == "gcs":
        return GcsStorage(settings.evidence_bucket)
    if settings.env not in ("local", "test"):
        raise RuntimeError("Local storage is only allowed when PRUFLO_ENV is local or test.")
    return LocalStorage(
        settings.local_storage_dir, settings.local_signing_key, settings.public_base_url
    )


def get_storage() -> Storage:
    """FastAPI dependency; tests override it."""
    return _default_storage()
