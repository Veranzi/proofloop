"""OAuth for Google Drive and SharePoint.

1. Endpoint 44 stores the folder, then returns the provider's consent URL
   with a signed ``state`` (tenant, kind, admin, return URL, expiry, nonce).
2. The provider sends the browser to ``/v1/connectors/oauth/callback``.
   The state is checked (signature, expiry, and its nonce, so it works
   once), the code is exchanged for a refresh token, the folder is checked,
   and the browser goes back to ``return_url?connector=<kind>&status=...``.

Only refresh tokens are kept, encrypted, and never returned. ``return_url``
must be one of the web app's origins, so the callback can't be used to
redirect people elsewhere.
"""

import base64
import hashlib
import hmac
import json
import secrets
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode, urlsplit

import httpx

from app.config import get_settings
from app.connectors import base
from app.connectors.base import ConnectorFailed
from app.enums import ConnectorKind
from app.services import secret_box

STATE_MINUTES = 15
CALLBACK_PATH = "/v1/connectors/oauth/callback"


@dataclass(frozen=True)
class Provider:
    authorize_url: str
    token_url: str
    scopes: str
    client_id: str
    client_secret: str
    extra: dict[str, str]


def provider(kind: ConnectorKind) -> Provider:
    settings = get_settings()
    if kind == ConnectorKind.GOOGLE_DRIVE:
        return Provider(
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://oauth2.googleapis.com/token",
            "https://www.googleapis.com/auth/drive.readonly",
            settings.google_oauth_client_id,
            settings.google_oauth_client_secret,
            # A refresh token every time, even if the admin agreed before.
            {"access_type": "offline", "prompt": "consent", "include_granted_scopes": "false"},
        )
    if kind == ConnectorKind.SHAREPOINT:
        return Provider(
            "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
            "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
            "https://graph.microsoft.com/Sites.Selected offline_access",
            settings.microsoft_oauth_client_id,
            settings.microsoft_oauth_client_secret,
            {"prompt": "select_account"},
        )
    raise ValueError(f"{kind} doesn't use OAuth")


def redirect_uri() -> str:
    return get_settings().public_base_url.rstrip("/") + CALLBACK_PATH


def check_return_url(url: str) -> str:
    settings = get_settings()
    parts = urlsplit(url)
    origin = f"{parts.scheme}://{parts.netloc}"
    allowed = set(settings.cors_origins)
    local = settings.env in ("local", "test") and parts.hostname in ("localhost", "127.0.0.1")
    if origin not in allowed and not local:
        raise ConnectorFailed("return_url must be a page of the Pruflo web app.")
    return url


def _signing_key() -> bytes:
    # Derived from the secrets key, so it's stable across instances.
    return hashlib.sha256(b"oauth-state:" + secret_box.key_material()).digest()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_state(
    tenant_id: str, kind: ConnectorKind, user_id: str, return_url: str
) -> tuple[str, str]:
    """Returns (state, nonce). Store the nonce on the connector; it's checked once."""
    nonce = secrets.token_urlsafe(16)
    claims = {
        "t": tenant_id,
        "k": kind.value,
        "u": user_id,
        "r": return_url,
        "n": nonce,
        "e": int(time.time()) + STATE_MINUTES * 60,
    }
    body = _b64(json.dumps(claims, separators=(",", ":")).encode())
    signature = _b64(hmac.new(_signing_key(), body.encode(), hashlib.sha256).digest())
    return f"{body}.{signature}", nonce


def read_state(state: str) -> dict[str, Any]:
    body, _, signature = state.partition(".")
    expected = _b64(hmac.new(_signing_key(), body.encode(), hashlib.sha256).digest())
    if not body or not hmac.compare_digest(expected, signature):
        raise ConnectorFailed("The sign-in link isn't valid. Start again from Integrations.")
    claims: dict[str, Any] = json.loads(_unb64(body))
    if claims["e"] < time.time():
        raise ConnectorFailed("The sign-in took too long. Start again from Integrations.")
    return claims


def authorization_url(kind: ConnectorKind, state: str) -> str:
    p = provider(kind)
    query = {
        "client_id": p.client_id,
        "redirect_uri": redirect_uri(),
        "response_type": "code",
        "scope": p.scopes,
        "state": state,
        **p.extra,
    }
    return f"{p.authorize_url}?{urlencode(query)}"


def _token_request(kind: ConnectorKind, data: dict[str, str]) -> dict[str, Any]:
    p = provider(kind)
    form = {"client_id": p.client_id, "client_secret": p.client_secret, **data}
    if kind == ConnectorKind.SHAREPOINT:
        form["scope"] = p.scopes
    try:
        with base.http_client() as client:
            response = client.post(p.token_url, data=form)
    except httpx.HTTPError as exc:
        raise ConnectorFailed("The sign-in service couldn't be reached. Try again.") from exc
    reply: dict[str, Any] = response.json() if response.content else {}
    if response.status_code != 200 or "access_token" not in reply:
        if reply.get("error") == "invalid_grant":
            raise ConnectorFailed("Access was withdrawn. Connect it again.")
        raise ConnectorFailed("The sign-in couldn't be completed. Try again.")
    return reply


def exchange_code(kind: ConnectorKind, code: str) -> dict[str, Any]:
    reply = _token_request(
        kind, {"grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri()}
    )
    if not reply.get("refresh_token"):
        raise ConnectorFailed("No lasting access was granted. Try again and allow access.")
    return reply


def access_token(kind: ConnectorKind, refresh_token: str) -> tuple[str, str | None]:
    """A fresh access token, and a new refresh token if the provider rotated it."""
    reply = _token_request(kind, {"grant_type": "refresh_token", "refresh_token": refresh_token})
    return str(reply["access_token"]), reply.get("refresh_token")
