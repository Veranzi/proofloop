"""Webhook endpoints: 37-42 (Docs/Integrations_API_Contract.md §2). Admins only."""

from datetime import datetime

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.permissions import Permission
from app.auth.principal import Principal, require
from app.db.models import WebhookDelivery, WebhookEndpoint
from app.db.session import get_db
from app.enums import WebhookEvent
from app.errors import bad_request, not_found
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit, secret_box, webhooks
from app.services.net_guard import UnsafeUrl, check_url

router = APIRouter(prefix="/admin/webhooks", tags=["integrations"])
ADMIN = Depends(require(Permission.ADMIN))
MAX_ENDPOINTS = 20


class DeliveryOut(BaseModel):
    id: str
    event: str
    status_code: int  # 0: the receiver couldn't be reached
    attempt: int
    at: datetime


class WebhookOut(BaseModel):
    id: str
    url: str
    description: str
    events: list[WebhookEvent]
    active: bool
    created_at: datetime
    recent_deliveries: list[DeliveryOut]


class WebhookCreated(WebhookOut):
    signing_secret: str  # returned only here, once


class WebhookIn(BaseModel):
    url: str = Field(min_length=8, max_length=2048)
    description: str = Field(default="", max_length=200)
    events: list[WebhookEvent] = Field(min_length=1)


class WebhookPatch(BaseModel):
    active: bool | None = None
    events: list[WebhookEvent] | None = Field(default=None, min_length=1)
    description: str | None = Field(default=None, max_length=200)


def _events(events: list[WebhookEvent]) -> list[str]:
    if WebhookEvent.PING in events:
        raise bad_request("ping is only sent by the test button.", field="events")
    return sorted({e.value for e in events})


def _delivery_out(d: WebhookDelivery) -> DeliveryOut:
    return DeliveryOut(
        id=d.id, event=d.event, status_code=d.status_code, attempt=d.attempt, at=d.at
    )


def _out(db: Session, endpoint: WebhookEndpoint) -> WebhookOut:
    recent = db.scalars(
        select(WebhookDelivery)
        .where(WebhookDelivery.endpoint_id == endpoint.id)
        .order_by(WebhookDelivery.at.desc(), WebhookDelivery.id.desc())
        .limit(5)
    ).all()
    return WebhookOut(
        id=endpoint.id,
        url=endpoint.url,
        description=endpoint.description,
        events=[WebhookEvent(e) for e in endpoint.events],
        active=endpoint.active,
        created_at=endpoint.created_at,
        recent_deliveries=[_delivery_out(d) for d in recent],
    )


def _load(db: Session, principal: Principal, webhook_id: str) -> WebhookEndpoint:
    endpoint = db.get(WebhookEndpoint, webhook_id)
    if endpoint is None or endpoint.tenant_id != principal.tenant_id:
        raise not_found("Webhook")
    return endpoint


@router.get("", response_model=Page[WebhookOut])
def list_webhooks(principal: Principal = ADMIN, db: Session = Depends(get_db)) -> Page[WebhookOut]:
    """37: each with its last 5 deliveries."""
    endpoints = db.scalars(
        select(WebhookEndpoint)
        .where(WebhookEndpoint.tenant_id == principal.tenant_id)
        .order_by(WebhookEndpoint.created_at.desc())
    ).all()
    return Page[WebhookOut](items=[_out(db, e) for e in endpoints], next_cursor=None)


@router.post("", response_model=WebhookCreated, status_code=201)
def create_webhook(
    body: WebhookIn, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> WebhookCreated:
    """38: the signing secret is in the response and never shown again."""
    try:
        url = check_url(body.url)
    except UnsafeUrl as exc:
        raise bad_request(str(exc), field="url") from exc
    count = len(
        db.scalars(
            select(WebhookEndpoint.id).where(WebhookEndpoint.tenant_id == principal.tenant_id)
        ).all()
    )
    if count >= MAX_ENDPOINTS:
        raise bad_request(f"An organisation can have at most {MAX_ENDPOINTS} webhooks.")
    secret = webhooks.new_signing_secret()
    endpoint = WebhookEndpoint(
        id=new_id("wh"),
        tenant_id=principal.tenant_id,
        url=url,
        description=body.description.strip(),
        events=_events(body.events),
        secret_ref=secret_box.seal(secret),
    )
    db.add(endpoint)
    db.flush()
    audit.record(
        db,
        principal,
        "webhook.created",
        "webhook",
        endpoint.id,
        details={"url": url, "events": endpoint.events},
    )
    db.commit()
    db.refresh(endpoint)
    return WebhookCreated(**_out(db, endpoint).model_dump(), signing_secret=secret)


@router.patch("/{webhook_id}", response_model=WebhookOut)
def update_webhook(
    webhook_id: str,
    body: WebhookPatch,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> WebhookOut:
    """39"""
    endpoint = _load(db, principal, webhook_id)
    if body.events is not None:
        endpoint.events = _events(body.events)
    if body.description is not None:
        endpoint.description = body.description.strip()
    if body.active is not None:
        if body.active and not endpoint.active:
            endpoint.failing_since = None  # a fresh start after a pause
        endpoint.active = body.active
    audit.record(
        db,
        principal,
        "webhook.updated",
        "webhook",
        endpoint.id,
        details=body.model_dump(exclude_unset=True, mode="json"),
    )
    db.commit()
    return _out(db, endpoint)


@router.delete("/{webhook_id}", status_code=204)
def delete_webhook(
    webhook_id: str, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> Response:
    """40"""
    endpoint = _load(db, principal, webhook_id)
    audit.record(
        db, principal, "webhook.deleted", "webhook", endpoint.id, details={"url": endpoint.url}
    )
    db.delete(endpoint)
    db.commit()
    return Response(status_code=204)


@router.post("/{webhook_id}/test", response_model=DeliveryOut)
def test_webhook(
    webhook_id: str, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> DeliveryOut:
    """41: send a ping now (no retries) and return the result."""
    endpoint = _load(db, principal, webhook_id)
    return _delivery_out(webhooks.send_test(db, endpoint))


@router.get("/{webhook_id}/deliveries", response_model=Page[DeliveryOut])
def deliveries(
    webhook_id: str,
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> Page[DeliveryOut]:
    """42: the delivery log, kept for 30 days."""
    endpoint = _load(db, principal, webhook_id)
    size = clamp_limit(limit)
    rows = db.scalars(
        after_cursor(
            select(WebhookDelivery)
            .where(WebhookDelivery.endpoint_id == endpoint.id)
            .order_by(WebhookDelivery.at.desc(), WebhookDelivery.id.desc())
            .limit(size + 1),
            WebhookDelivery.at,
            WebhookDelivery.id,
            cursor,
        )
    ).all()
    return Page[DeliveryOut](
        items=[_delivery_out(d) for d in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda d: (d.at, d.id)),
    )
