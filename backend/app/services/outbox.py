"""Transactional outbox: events are written with the change that caused them,
then published by the dispatcher (worker module). Payloads carry IDs only."""

from typing import Any, Literal

from sqlalchemy.orm import Session

from app.db.models import OutboxEvent
from app.ids import new_id

Topic = Literal["processing", "webhook"]


def emit(
    db: Session, tenant_id: str, topic: Topic, event_type: str, payload: dict[str, Any]
) -> OutboxEvent:
    event = OutboxEvent(
        id=new_id("evt"), tenant_id=tenant_id, topic=topic, type=event_type, payload=payload
    )
    db.add(event)
    return event
