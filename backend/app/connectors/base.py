"""What every connector shares: which sources are offered, the HTTP client,
stored credentials, and mapping a source's folder or order to a case."""

import json
from typing import Any

import httpx
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db.models import Case, Connector
from app.enums import ConnectorKind
from app.services import cases as case_service
from app.services import secret_box

TIMEOUT = httpx.Timeout(30.0, connect=10.0)


class ConnectorFailed(Exception):
    """A problem a person can act on; its message is shown as the connector's detail."""


def available() -> set[ConnectorKind]:
    """Sources that can be connected with this deployment's settings."""
    settings = get_settings()
    kinds = {ConnectorKind.ODOO}
    if settings.inbound_email_domain and settings.inbound_email_token:
        kinds.add(ConnectorKind.EMAIL_INBOX)
    if settings.google_oauth_client_id and settings.google_oauth_client_secret:
        kinds.add(ConnectorKind.GOOGLE_DRIVE)
    if settings.microsoft_oauth_client_id and settings.microsoft_oauth_client_secret:
        kinds.add(ConnectorKind.SHAREPOINT)
    return kinds


def http_client() -> httpx.Client:
    """Every outgoing call goes through here. Replaced in tests."""
    return httpx.Client(timeout=TIMEOUT, follow_redirects=False)


def credentials(connector: Connector) -> dict[str, Any]:
    if not connector.secret:
        raise ConnectorFailed("The stored credentials are missing. Connect it again.")
    loaded: dict[str, Any] = json.loads(secret_box.open_sealed(connector.secret))
    return loaded


def store_credentials(connector: Connector, values: dict[str, Any]) -> None:
    connector.secret = secret_box.seal(json.dumps(values))


def case_for(
    db: Session,
    connector: Connector,
    key: str,
    title: str,
    *,
    hint: str = "",
) -> Case:
    """The case that files grouped under ``key`` (a folder, an order) go to.

    A case reference such as PL-001 in ``title`` or ``hint`` picks that case;
    otherwise a new case is opened the first time the key is seen and
    remembered in the connector's state.
    """
    cases: dict[str, str] = dict(connector.state.get("cases", {}))
    case = db.get(Case, cases[key]) if key in cases else None
    if case is None or case.tenant_id != connector.tenant_id:
        case = case_service.find_by_reference(db, connector.tenant_id, f"{title} {hint}")
    if case is None:
        case = case_service.create_imported(
            db,
            connector.tenant_id,
            title,
            created_by=connector.connected_by,
            source=connector.kind,
        )
    if cases.get(key) != case.id:
        cases[key] = case.id
        connector.state = {**connector.state, "cases": cases}
    return case
