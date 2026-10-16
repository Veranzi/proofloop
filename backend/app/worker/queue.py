"""Getting work from the outbox to the worker.

Changes write an ``outbox_events`` row in their own transaction. The
dispatcher then publishes ``processing`` events to Pub/Sub and marks them
published, so a crash between the database write and the publish can't lose
work: the next dispatch picks the row up again. Publishing twice is harmless
because jobs are idempotent.

Locally (``PRUFLO_QUEUE_BACKEND=inline``) there's no Pub/Sub: the API runs
the job itself right after responding.
"""

import json
import logging
from collections.abc import Callable
from contextlib import AbstractContextManager
from datetime import UTC, datetime
from functools import lru_cache
from typing import Any, Protocol

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db.models import OutboxEvent
from app.pipeline.ocr import OcrProvider, get_ocr_provider
from app.storage.backend import Storage, get_storage

logger = logging.getLogger("pruflo.queue")

PROCESS_EVIDENCE = "evidence.process"


class Publisher(Protocol):
    def publish(self, event: OutboxEvent) -> None: ...


class PubSubPublisher:
    def __init__(self, project: str, topic: str) -> None:
        from google.cloud.pubsub_v1 import PublisherClient

        self._client = PublisherClient()
        self._topic = self._client.topic_path(project, topic)

    def publish(self, event: OutboxEvent) -> None:
        future = self._client.publish(
            self._topic,
            json.dumps(event.payload).encode(),
            type=event.type,
            event_id=event.id,
            tenant_id=event.tenant_id,
        )
        future.result(timeout=30)


class InlinePublisher:
    """Publishes nowhere: ``Queue.kick`` runs the events in-process instead."""

    def publish(self, event: OutboxEvent) -> None:
        return None


def dispatch_outbox(db: Session, publisher: Publisher, limit: int = 100) -> list[OutboxEvent]:
    """Publish unpublished processing events. Safe to run from several places at once."""
    events = db.scalars(
        select(OutboxEvent)
        .where(OutboxEvent.topic == "processing", OutboxEvent.published_at.is_(None))
        .order_by(OutboxEvent.created_at)
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    published: list[OutboxEvent] = []
    for event in events:
        try:
            publisher.publish(event)
        except Exception:
            event.attempts += 1
            logger.exception("publish failed for %s", event.id)
            continue
        event.published_at = datetime.now(UTC)
        published.append(event)
    db.commit()
    return published


def handle_event(
    db: Session, storage: Storage, ocr: OcrProvider | None, event_type: str, payload: dict[str, Any]
) -> str:
    """Route one message to its job. Raises RetryLater to be redelivered."""
    from app.services.reports import GENERATE_REPORT
    from app.worker.jobs import run_processing_job, run_report_job

    if event_type == PROCESS_EVIDENCE:
        return run_processing_job(
            db, storage, ocr, str(payload["evidence_id"]), str(payload["job_id"])
        )
    if event_type == GENERATE_REPORT:
        return run_report_job(db, storage, str(payload["report_id"]))
    logger.warning("ignoring unknown event type %s", event_type)
    return "skipped"


SessionScope = Callable[[], AbstractContextManager[Session]]


class Queue:
    def __init__(
        self,
        session_scope: SessionScope,
        publisher: Publisher,
        storage: Storage,
        ocr: OcrProvider | None,
        inline: bool,
    ) -> None:
        self.session_scope = session_scope
        self.publisher = publisher
        self.storage = storage
        self.ocr = ocr
        self.inline = inline

    def kick(self) -> None:
        """Run after a request commits. Never raises: the outbox keeps the work safe."""
        from app.worker.jobs import RetryLater

        try:
            with self.session_scope() as db:
                events = [(e.type, dict(e.payload)) for e in dispatch_outbox(db, self.publisher)]
            if not self.inline:
                return
            for event_type, payload in events:
                with self.session_scope() as db:
                    try:
                        handle_event(db, self.storage, self.ocr, event_type, payload)
                    except RetryLater:
                        # No redelivery locally; `python -m app.worker drain` retries.
                        logger.warning("job left for retry: %s", payload)
        except Exception:
            logger.exception("queue kick failed; the outbox will be retried")


@lru_cache
def _default_queue() -> Queue:
    from app.db.session import _session_factory

    settings = get_settings()
    inline = settings.queue_backend == "inline"
    publisher: Publisher = (
        InlinePublisher()
        if inline
        else PubSubPublisher(settings.gcp_project, settings.pubsub_topic)
    )
    return Queue(_session_factory(), publisher, get_storage(), get_ocr_provider(), inline)


def get_queue() -> Queue:
    """FastAPI dependency; tests override it."""
    return _default_queue()
