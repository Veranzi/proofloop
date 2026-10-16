"""Worker commands for local development and operations.

Process every file that's waiting or due a retry, right now, in this process:

    python -m app.worker drain

On Cloud Run this isn't needed: Pub/Sub delivers each job to the worker.
"""

import argparse
import contextlib

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db.models import EvidenceFile, ProcessingJob
from app.db.session import get_engine
from app.enums import EvidenceStatus
from app.pipeline.ocr import get_ocr_provider
from app.storage.backend import get_storage
from app.worker.jobs import RetryLater, run_processing_job
from app.worker.queue import (
    PROCESS_EVIDENCE,
    InlinePublisher,
    dispatch_outbox,
    handle_event,
    message_for,
)

WAITING = [EvidenceStatus.QUEUED, EvidenceStatus.FAILED_RETRYABLE, EvidenceStatus.EXTRACTING]


def _send_pending_events(db: Session) -> None:
    for message_type, payload in [message_for(e) for e in dispatch_outbox(db, InlinePublisher())]:
        if message_type == PROCESS_EVIDENCE:
            continue  # evidence jobs are picked up below from the evidence status
        with contextlib.suppress(RetryLater):
            handle_event(db, get_storage(), get_ocr_provider(), message_type, payload)


def drain(db: Session) -> dict[str, int]:
    _send_pending_events(db)
    latest = (
        select(ProcessingJob.evidence_id, func.max(ProcessingJob.created_at).label("at"))
        .group_by(ProcessingJob.evidence_id)
        .subquery()
    )
    jobs = db.execute(
        select(ProcessingJob.evidence_id, ProcessingJob.id)
        .join(
            latest,
            (latest.c.evidence_id == ProcessingJob.evidence_id)
            & (latest.c.at == ProcessingJob.created_at),
        )
        .join(EvidenceFile, EvidenceFile.id == ProcessingJob.evidence_id)
        .where(EvidenceFile.status.in_(WAITING))
    ).all()
    counts: dict[str, int] = {}
    storage, ocr = get_storage(), get_ocr_provider()
    for evidence_id, job_id in jobs:
        try:
            outcome = run_processing_job(db, storage, ocr, evidence_id, job_id)
        except RetryLater:
            outcome = "retry_later"
        counts[outcome] = counts.get(outcome, 0) + 1
    _send_pending_events(db)  # e.g. evidence.processed webhooks from the jobs above
    from app.services import webhooks

    webhooks.retry_due(db)
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.worker")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("drain", help="process waiting files now, in this process")
    sub.add_parser("weekly-summary", help="send this week's summaries now")
    args = parser.parse_args()
    with Session(get_engine()) as db:
        if args.command == "weekly-summary":
            from app.services import notifications

            print(f"Sent {notifications.weekly_summary(db)} summaries.")  # noqa: T201
            _send_pending_events(db)
            return
        counts = drain(db)
    print(", ".join(f"{k}: {v}" for k, v in sorted(counts.items())) or "Nothing waiting.")  # noqa: T201


if __name__ == "__main__":
    main()
