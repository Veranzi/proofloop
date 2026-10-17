"""Poll the sources that need it (Odoo, Drive, SharePoint).

Cloud Scheduler calls the worker's ``/tasks/sync-connectors`` every 15
minutes. Each source runs on its own: a failure marks only that connector
``error`` with a message an admin can act on, and the next successful run
puts it back to ``connected``.
"""

import logging
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.connectors import folders, odoo
from app.connectors.base import ConnectorFailed
from app.db.models import Connector
from app.enums import ConnectorKind, ConnectorStatus
from app.storage.backend import Storage

logger = logging.getLogger("pruflo.connectors")

SYNCERS: dict[ConnectorKind, Callable[[Session, Storage, Connector], int]] = {
    ConnectorKind.ODOO: odoo.sync,
    ConnectorKind.GOOGLE_DRIVE: folders.sync,
    ConnectorKind.SHAREPOINT: folders.sync,
}


def sync_one(db: Session, storage: Storage, connector: Connector) -> int:
    kind = ConnectorKind(connector.kind)
    try:
        imported = SYNCERS[kind](db, storage, connector)
    except ConnectorFailed as exc:
        db.rollback()
        connector.status = ConnectorStatus.ERROR
        connector.detail = str(exc)[:500]
        connector.last_synced_at = datetime.now(UTC)
        db.commit()
        logger.warning("connector %s for %s failed: %s", kind, connector.tenant_id, exc)
        return 0
    connector.status = ConnectorStatus.CONNECTED
    connector.detail = str(connector.state.get("display", connector.detail))[:500]
    connector.last_synced_at = datetime.now(UTC)
    db.commit()
    return imported


def sync_due(db: Session, storage: Storage, *, force: bool = False) -> dict[str, int]:
    cutoff = datetime.now(UTC) - timedelta(minutes=get_settings().connector_sync_minutes - 1)
    query = select(Connector.id).where(
        Connector.kind.in_(list(SYNCERS)),
        Connector.status.in_([ConnectorStatus.CONNECTED, ConnectorStatus.ERROR]),
        Connector.secret.is_not(None),
    )
    if not force:
        query = query.where(
            (Connector.last_synced_at.is_(None)) | (Connector.last_synced_at < cutoff)
        )
    totals = {"connectors": 0, "imported": 0, "failed": 0}
    for connector_id in db.scalars(query).all():
        connector = db.scalar(
            select(Connector)
            .where(Connector.id == connector_id)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if connector is None or (
            not force and connector.last_synced_at and connector.last_synced_at >= cutoff
        ):
            db.rollback()
            continue  # another run has it
        # Claim it: imports commit as they go, so the row lock alone won't last.
        connector.last_synced_at = datetime.now(UTC)
        db.commit()
        totals["connectors"] += 1
        try:
            totals["imported"] += sync_one(db, storage, connector)
        except Exception:
            # Unexpected: keep going with the other organisations.
            db.rollback()
            totals["failed"] += 1
            logger.exception("connector %s crashed", connector_id)
            continue
        if connector.status == ConnectorStatus.ERROR:
            totals["failed"] += 1
    return totals
