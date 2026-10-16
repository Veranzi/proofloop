"""Webhook delivery (Docs/Integrations_API_Contract.md §2).

Events reach this module through the outbox, never from the request path:
``fanout`` sends a new event to every subscribed endpoint, and ``retry_due``
re-sends failed deliveries on the contract's schedule.
"""

import hashlib
import hmac
import json
import logging
import secrets
import string
import time
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.db.models import OutboxEvent, WebhookDelivery, WebhookEndpoint
from app.enums import WebhookEvent
from app.ids import new_id
from app.services import audit, secret_box
from app.services.net_guard import UnsafeUrl, check_url

logger = logging.getLogger("pruflo.webhooks")

SUBSCRIBABLE = [e for e in WebhookEvent if e != WebhookEvent.PING]
# Wait before attempts 2..7; together they stay within 24 hours.
RETRY_SCHEDULE = [
    timedelta(minutes=1),
    timedelta(minutes=5),
    timedelta(minutes=30),
    timedelta(hours=2),
    timedelta(hours=6),
    timedelta(hours=12),
]
PAUSE_AFTER = timedelta(days=3)
KEEP_DELIVERIES = timedelta(days=30)
TIMEOUT_SECONDS = 10
_ALPHABET = string.ascii_letters + string.digits


def new_signing_secret() -> str:
    return "whsec_" + "".join(secrets.choice(_ALPHABET) for _ in range(32))


def signature(secret: str, timestamp: int, body: bytes) -> str:
    mac = hmac.new(secret.encode(), f"{timestamp}.".encode() + body, hashlib.sha256)
    return f"t={timestamp},v1={mac.hexdigest()}"


def transport(url: str, headers: dict[str, str], body: bytes) -> int:
    """POST and return the status code, or 0 if the receiver couldn't be reached.
    Replaced in tests."""
    try:
        check_url(url)  # again, right before sending: DNS may have changed
        with httpx.Client(timeout=TIMEOUT_SECONDS, follow_redirects=False) as client:
            return client.post(url, headers=headers, content=body).status_code
    except (httpx.HTTPError, UnsafeUrl) as exc:
        logger.info("webhook delivery failed: %s", type(exc).__name__)
        return 0


def _body(
    event_id: str, event_type: str, created_at: datetime, tenant_id: str, data: dict[str, Any]
) -> bytes:
    return json.dumps(
        {
            "id": event_id,  # the same on every retry, so receivers can drop duplicates
            "type": event_type,
            "created_at": created_at.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "tenant_id": tenant_id,
            "data": data,  # IDs only, never document content
        },
        separators=(",", ":"),
    ).encode()


def deliver(
    db: Session,
    endpoint: WebhookEndpoint,
    event_id: str,
    event_type: str,
    created_at: datetime,
    data: dict[str, Any],
    attempt: int,
    first_attempt_at: datetime | None = None,
    retry: bool = True,
) -> WebhookDelivery:
    delivery_id = new_id("dlv")
    body = _body(event_id, event_type, created_at, endpoint.tenant_id, data)
    secret = secret_box.open_sealed(endpoint.secret_ref)
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Pruflo-Webhooks/1",
        "X-Pruflo-Event": event_type,
        "X-Pruflo-Delivery": delivery_id,
        "X-Pruflo-Signature": signature(secret, int(time.time()), body),
    }
    status = transport(endpoint.url, headers, body)
    now = datetime.now(UTC)
    ok = 200 <= status < 300
    next_at = None
    started = first_attempt_at or now
    if not ok and retry and attempt <= len(RETRY_SCHEDULE):
        candidate = now + RETRY_SCHEDULE[attempt - 1]
        if candidate - started <= timedelta(hours=24):
            next_at = candidate
    delivery = WebhookDelivery(
        id=delivery_id,
        endpoint_id=endpoint.id,
        event_id=event_id,
        event=event_type,
        attempt=attempt,
        status_code=status,
        at=now,
        next_attempt_at=next_at,
    )
    db.add(delivery)
    if event_type != WebhookEvent.PING:
        _track_health(db, endpoint, ok, now)
    return delivery


def _track_health(db: Session, endpoint: WebhookEndpoint, ok: bool, now: datetime) -> None:
    if ok:
        endpoint.failing_since = None
        return
    if endpoint.failing_since is None:
        endpoint.failing_since = now
    elif now - endpoint.failing_since >= PAUSE_AFTER and endpoint.active:
        endpoint.active = False
        audit.record_system(
            db,
            endpoint.tenant_id,
            "webhook.paused",
            "webhook",
            endpoint.id,
            details={"reason": "failing for 3 days", "url": endpoint.url},
        )
        logger.warning("webhook %s paused after 3 days of failures", endpoint.id)


def fanout(db: Session, event_id: str) -> int:
    """Send one outbox event to every active endpoint subscribed to it. Safe to repeat."""
    event = db.get(OutboxEvent, event_id)
    if event is None or event.topic != "webhook":
        return 0
    endpoints = db.scalars(
        select(WebhookEndpoint).where(
            WebhookEndpoint.tenant_id == event.tenant_id,
            WebhookEndpoint.active.is_(True),
            WebhookEndpoint.events.contains([event.type]),
        )
    ).all()
    already = set(
        db.scalars(select(WebhookDelivery.endpoint_id).where(WebhookDelivery.event_id == event.id))
    )
    sent = 0
    for endpoint in endpoints:
        if endpoint.id in already:
            continue
        deliver(db, endpoint, event.id, event.type, event.created_at, dict(event.payload), 1)
        sent += 1
    db.commit()
    return sent


def retry_due(db: Session, now: datetime | None = None) -> int:
    """Re-send failed deliveries whose time has come, and drop logs past 30 days."""
    now = now or datetime.now(UTC)
    due = db.scalars(
        select(WebhookDelivery)
        .where(WebhookDelivery.next_attempt_at.is_not(None), WebhookDelivery.next_attempt_at <= now)
        .order_by(WebhookDelivery.next_attempt_at)
        .limit(200)
        .with_for_update(skip_locked=True)
    ).all()
    sent = 0
    for previous in due:
        previous.next_attempt_at = None
        endpoint = db.get(WebhookEndpoint, previous.endpoint_id)
        event = db.get(OutboxEvent, previous.event_id)
        if endpoint is None or not endpoint.active or event is None:
            continue
        first = db.scalar(
            select(WebhookDelivery.at).where(
                WebhookDelivery.endpoint_id == endpoint.id,
                WebhookDelivery.event_id == event.id,
                WebhookDelivery.attempt == 1,
            )
        )
        deliver(
            db,
            endpoint,
            event.id,
            event.type,
            event.created_at,
            dict(event.payload),
            previous.attempt + 1,
            first_attempt_at=first,
        )
        sent += 1
    db.execute(delete(WebhookDelivery).where(WebhookDelivery.at < now - KEEP_DELIVERIES))
    db.commit()
    return sent


def send_test(db: Session, endpoint: WebhookEndpoint) -> WebhookDelivery:
    """Endpoint 41: a ping, sent now, never retried."""
    delivery = deliver(
        db,
        endpoint,
        new_id("evt"),
        WebhookEvent.PING.value,
        datetime.now(UTC),
        {},
        attempt=1,
        retry=False,
    )
    db.commit()
    return delivery
