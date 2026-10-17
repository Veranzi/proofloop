"""Document sources: endpoints 43-45 (Docs/Integrations_API_Contract.md §3),
plus the two public entry points the sources call back on:

- ``GET /v1/connectors/oauth/callback``: Google and Microsoft send the
  admin's browser here after consent.
- ``POST /v1/inbound/email``: the mail service posts each message here.

A source is offered only when this deployment has what it needs (the inbound
mail domain, an OAuth app); otherwise it's listed as coming_soon. SAP has no
importer. Credentials are stored encrypted and never returned.
"""

import hmac
import json
import logging
from datetime import UTC, datetime
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from fastapi import APIRouter, BackgroundTasks, Depends, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import PlainTextResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.auth.permissions import ROLE_PERMISSIONS, Permission
from app.auth.principal import Principal, require
from app.config import get_settings
from app.connectors import email_inbox, folders, oauth, odoo
from app.connectors.base import ConnectorFailed, available, store_credentials
from app.db.models import Connector, Membership, Tenant, User
from app.db.session import get_db
from app.enums import ConnectorKind, ConnectorStatus, Role
from app.errors import ApiError, unauthorized
from app.ids import new_id
from app.services import audit
from app.worker.queue import Queue, get_queue

logger = logging.getLogger("pruflo.connectors")

router = APIRouter(prefix="/admin/connectors", tags=["integrations"])
public = APIRouter(tags=["integrations"])
ADMIN = Depends(require(Permission.ADMIN))
OAUTH_KINDS = {ConnectorKind.GOOGLE_DRIVE, ConnectorKind.SHAREPOINT}


class ConnectorOut(BaseModel):
    kind: ConnectorKind
    status: ConnectorStatus
    detail: str
    connected_at: datetime | None


class ConnectorList(BaseModel):
    items: list[ConnectorOut]


def _out(kind: ConnectorKind, row: Connector | None, offered: set[ConnectorKind]) -> ConnectorOut:
    if kind not in offered:
        return ConnectorOut(
            kind=kind, status=ConnectorStatus.COMING_SOON, detail="", connected_at=None
        )
    if row is None or row.status == ConnectorStatus.NOT_CONNECTED:
        return ConnectorOut(
            kind=kind, status=ConnectorStatus.NOT_CONNECTED, detail="", connected_at=None
        )
    return ConnectorOut(
        kind=kind,
        status=ConnectorStatus(row.status),
        detail=row.detail,
        connected_at=row.connected_at,
    )


@router.get("", response_model=ConnectorList)
def list_connectors(principal: Principal = ADMIN, db: Session = Depends(get_db)) -> ConnectorList:
    """43: always all five kinds."""
    rows = {
        c.kind: c
        for c in db.scalars(select(Connector).where(Connector.tenant_id == principal.tenant_id))
    }
    offered = available()
    return ConnectorList(items=[_out(kind, rows.get(kind), offered) for kind in ConnectorKind])


def _row(db: Session, tenant_id: str, kind: ConnectorKind) -> Connector:
    row = db.scalar(
        select(Connector).where(Connector.tenant_id == tenant_id, Connector.kind == kind)
    )
    if row is None:
        row = Connector(id=new_id("con"), tenant_id=tenant_id, kind=kind, state={})
        db.add(row)
    return row


@router.put("/{kind}", response_model=None)
def connect(
    kind: ConnectorKind,
    body: dict[str, Any],
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> ConnectorOut | dict[str, str]:
    """44: email inbox and Odoo connect at once; Drive and SharePoint return
    the provider's consent URL. Credentials are never returned."""
    if kind not in available():
        raise ApiError(
            400,
            "connector_not_available",
            "This document source isn't available yet.",
            field="kind",
        )
    try:
        if kind in OAUTH_KINDS:
            return _start_oauth(db, principal, kind, body)
        row = _row(db, principal.tenant_id, kind)
        if kind == ConnectorKind.EMAIL_INBOX:
            tenant = db.get(Tenant, principal.tenant_id)
            assert tenant is not None  # noqa: S101 (the principal's tenant exists)
            email_inbox.connect(db, row, tenant)
        else:
            creds, state = odoo.connect(body)
            store_credentials(row, {**creds})
            row.state = {**state, "display": creds["url"]}
            row.detail = creds["url"]
            row.status = ConnectorStatus.CONNECTED
            row.connected_at = datetime.now(UTC)
    except ConnectorFailed as exc:
        db.rollback()
        raise ApiError(400, "connector_failed", str(exc)) from exc
    row.connected_by = principal.user_id
    audit.record(
        db, principal, "connector.connected", "connector", kind, details={"detail": row.detail}
    )
    db.commit()
    return _out(kind, row, {kind})


def _start_oauth(
    db: Session, principal: Principal, kind: ConnectorKind, body: dict[str, Any]
) -> dict[str, str]:
    folder = str(body.get("folder", "")).strip()
    if not folder:
        raise ConnectorFailed("Paste the folder link.")
    if kind == ConnectorKind.GOOGLE_DRIVE:
        folders.drive_folder_id(folder)  # a readable error now, not after consent
    return_url = oauth.check_return_url(str(body.get("return_url", "")))
    state, nonce = oauth.make_state(principal.tenant_id, kind, principal.user_id or "", return_url)
    row = _row(db, principal.tenant_id, kind)
    # A connected source keeps working until the new consent completes.
    row.state = {**row.state, "pending": {"folder_link": folder, "nonce": nonce}}
    db.commit()
    return {"authorization_url": oauth.authorization_url(kind, state)}


def _back(return_url: str, kind: str, status: str, message: str = "") -> RedirectResponse:
    parts = urlsplit(return_url)
    query = [
        (k, v) for k, v in parse_qsl(parts.query) if k not in ("connector", "status", "message")
    ]
    query += [("connector", kind), ("status", status)]
    if message:
        query.append(("message", message))
    return RedirectResponse(urlunsplit(parts._replace(query=urlencode(query))), status_code=303)


@public.get("/connectors/oauth/callback", include_in_schema=False, response_model=None)
def oauth_callback(
    state: str = Query(default=""),
    code: str = Query(default=""),
    error: str = Query(default=""),
    db: Session = Depends(get_db),
) -> Response:
    """Where Google and Microsoft send the admin after consent."""
    try:
        claims = oauth.read_state(state)
    except (ConnectorFailed, ValueError, KeyError) as exc:
        message = str(exc) if isinstance(exc, ConnectorFailed) else "The sign-in link isn't valid."
        return PlainTextResponse(message, status_code=400)
    kind, return_url = ConnectorKind(claims["k"]), str(claims["r"])
    row = db.scalar(
        select(Connector).where(Connector.tenant_id == claims["t"], Connector.kind == kind)
    )
    pending = (row.state.get("pending") if row else None) or {}
    if row is None or not hmac.compare_digest(str(pending.get("nonce", "")), str(claims["n"])):
        return _back(return_url, kind, "error", "This sign-in link was already used.")
    row.state = {k: v for k, v in row.state.items() if k != "pending"}
    db.commit()
    if error or not code:
        return _back(return_url, kind, "error", "Access wasn't granted.")
    user = db.get(User, claims["u"])
    role = db.scalar(
        select(Membership.role).where(
            Membership.user_id == claims["u"], Membership.tenant_id == claims["t"]
        )
    )
    if user is None or not user.active or role != Role.ADMIN:
        return _back(return_url, kind, "error", "Only an admin can connect a document source.")
    try:
        tokens = oauth.exchange_code(kind, code)
        row.state = {**row.state, "folder_link": pending["folder_link"]}
        name = folders.finish_connect(
            row, str(tokens["refresh_token"]), str(tokens["access_token"])
        )
    except ConnectorFailed as exc:
        db.rollback()
        return _back(return_url, kind, "error", str(exc))
    display = name or str(pending["folder_link"])
    row.state = {**row.state, "display": display}
    row.detail = display[:500]
    row.status = ConnectorStatus.CONNECTED
    row.connected_at = datetime.now(UTC)
    row.connected_by = user.id
    row.last_synced_at = None  # import on the next scheduled run
    principal = Principal(
        tenant_id=row.tenant_id,
        permissions=ROLE_PERMISSIONS[Role.ADMIN],
        user=user,
        role=Role.ADMIN,
    )
    audit.record(
        db, principal, "connector.connected", "connector", kind, details={"detail": row.detail}
    )
    db.commit()
    return _back(return_url, kind, "connected")


@router.delete("/{kind}", status_code=204)
def disconnect(
    kind: ConnectorKind, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> Response:
    """45: forget stored credentials and stop importing. Evidence already imported stays."""
    removed = db.execute(
        delete(Connector).where(Connector.tenant_id == principal.tenant_id, Connector.kind == kind)
    ).rowcount
    if removed:
        audit.record(db, principal, "connector.removed", "connector", kind)
        db.commit()
    return Response(status_code=204)


def _inbound_token_ok(request: Request) -> bool:
    expected = get_settings().inbound_email_token
    given = request.headers.get("X-Pruflo-Inbound-Token") or request.query_params.get("token", "")
    return bool(expected) and hmac.compare_digest(given.encode(), expected.encode())


def _raw_message(content_type: str, body: bytes) -> tuple[bytes, list[str]]:
    """The MIME message and envelope recipients, from a raw post or a form post
    (SendGrid's ``email``/``envelope`` fields, Mailgun's ``body-mime``/``recipient``)."""
    if not content_type.startswith("multipart/form-data"):
        return body, []
    form = BytesParser(_class=EmailMessage, policy=policy.HTTP).parsebytes(
        f"Content-Type: {content_type}\r\n\r\n".encode() + body
    )
    fields: dict[str, bytes] = {}
    for part in form.iter_parts():
        name = part.get_param("name", header="content-disposition")
        payload = part.get_payload(decode=True)
        if name and isinstance(payload, bytes):
            fields[str(name)] = payload
    raw = fields.get("email") or fields.get("body-mime") or b""
    recipients: list[str] = []
    if "envelope" in fields:
        try:
            recipients = [str(a) for a in json.loads(fields["envelope"]).get("to", [])]
        except (ValueError, AttributeError):
            recipients = []
    if "recipient" in fields:
        recipients += [a.strip() for a in fields["recipient"].decode().split(",")]
    return raw, recipients


@public.post("/inbound/email", include_in_schema=False)
async def inbound_email(
    request: Request,
    background: BackgroundTasks,
    db: Session = Depends(get_db),
    queue: Queue = Depends(get_queue),
) -> dict[str, Any]:
    """The mail service's delivery. Answers 200 for anything it shouldn't retry."""
    if ConnectorKind.EMAIL_INBOX not in available():
        raise ApiError(404, "not_found", "Not found.")
    if not _inbound_token_ok(request):
        raise unauthorized()
    declared = int(request.headers.get("content-length") or 0)
    if declared > email_inbox.MAX_MESSAGE_BYTES * 2:
        return {"accepted": False, "reason": "message_too_large"}
    body = await request.body()
    raw, recipients = _raw_message(request.headers.get("content-type", ""), body)
    if not raw:
        return {"accepted": False, "reason": "no_message"}
    # Database and storage work is blocking: keep it off the event loop.
    result = await run_in_threadpool(email_inbox.handle, db, queue.storage, raw, recipients)
    if result.imported:
        background.add_task(queue.kick)  # after the response; the outbox keeps it safe
    return {
        "accepted": result.accepted,
        "reason": result.reason,
        "case_id": result.case_id,
        "imported": len(result.imported),
        "skipped": len(result.skipped),
    }
