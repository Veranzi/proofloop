"""Encrypt secrets the API has to read back (webhook signing secrets).

API keys are hashed instead, because the API never needs them again.
"""

import base64
import hashlib
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

from app.config import get_settings


@lru_cache
def _fernet() -> Fernet:
    settings = get_settings()
    if settings.secrets_key:
        return Fernet(settings.secrets_key.encode())
    if settings.env not in ("local", "test"):
        raise RuntimeError("Set PRUFLO_SECRETS_KEY (from Secret Manager) to store secrets.")
    # Local and test only: a stable key derived from the local database password.
    digest = hashlib.sha256(f"pruflo-local:{settings.db_password}".encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def seal(secret: str) -> str:
    return _fernet().encrypt(secret.encode()).decode()


def open_sealed(token: str) -> str:
    try:
        return _fernet().decrypt(token.encode()).decode()
    except InvalidToken as exc:
        raise RuntimeError(
            "A stored secret couldn't be decrypted: wrong PRUFLO_SECRETS_KEY?"
        ) from exc
