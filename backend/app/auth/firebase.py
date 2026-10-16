"""Firebase ID token and App Check verification.

The user's identity always comes from a verified token, never from the
request body.
"""

from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import firebase_admin
import jwt
from firebase_admin import app_check, auth

from app.config import get_settings
from app.errors import unauthorized

DEV_TOKEN_PREFIX = "dev:"  # noqa: S105 (a prefix, not a secret)


@dataclass(frozen=True)
class FirebaseIdentity:
    uid: str
    email: str
    email_verified: bool
    name: str


@lru_cache
def _firebase_app() -> firebase_admin.App:
    # On Cloud Run this uses the service account; no key file is needed.
    settings = get_settings()
    project = settings.firebase_project or settings.gcp_project
    return firebase_admin.initialize_app(options={"projectId": project})


def dev_mode_enabled() -> bool:
    settings = get_settings()
    # Never honoured outside local and test, whatever the flag says.
    return settings.auth_dev_mode and settings.env in ("local", "test")


def _verify_dev_token(token: str) -> FirebaseIdentity:
    # "dev:<uid>:<email>" — lets local tools and tests act as a user.
    parts = token.removeprefix(DEV_TOKEN_PREFIX).split(":", 1)
    if len(parts) != 2 or not parts[0] or "@" not in parts[1]:
        raise unauthorized("Malformed development token.")
    uid, email = parts
    return FirebaseIdentity(uid=uid, email=email.lower(), email_verified=True, name="")


def verify_id_token(token: str) -> FirebaseIdentity:
    if token.startswith(DEV_TOKEN_PREFIX):
        if not dev_mode_enabled():
            raise unauthorized("Invalid token.")
        return _verify_dev_token(token)
    try:
        claims: dict[str, Any] = auth.verify_id_token(
            token, app=_firebase_app(), check_revoked=True
        )
    except (auth.RevokedIdTokenError, auth.UserDisabledError) as exc:
        raise unauthorized("Your session has ended. Sign in again.") from exc
    except (ValueError, auth.InvalidIdTokenError, auth.CertificateFetchError) as exc:
        raise unauthorized("Invalid token.") from exc
    return FirebaseIdentity(
        uid=str(claims["uid"]),
        email=str(claims.get("email", "")).lower(),
        email_verified=bool(claims.get("email_verified", False)),
        name=str(claims.get("name", "")),
    )


def verify_app_check(token: str | None) -> None:
    """Defence in depth only: App Check is never a substitute for authorization."""
    settings = get_settings()
    if not settings.app_check_required or settings.env in ("local", "test"):
        return
    if not token:
        raise unauthorized("Missing App Check token.")
    try:
        app_check.verify_token(token, app=_firebase_app())
    except (ValueError, jwt.PyJWTError) as exc:
        raise unauthorized("Invalid App Check token.") from exc
