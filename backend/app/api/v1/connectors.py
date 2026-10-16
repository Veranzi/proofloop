"""Document sources: endpoints 43-45 (Docs/Integrations_API_Contract.md §3).

No importer exists yet (an inbound mail service, Google and Microsoft OAuth
apps, and an Odoo poller are needed), so every source reports coming_soon
and connecting is refused. Saying "connected" when nothing imports would
mislead people. Admins only.
"""

from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.auth.permissions import Permission
from app.auth.principal import Principal, require
from app.db.models import Connector
from app.db.session import get_db
from app.enums import ConnectorKind, ConnectorStatus
from app.errors import ApiError
from app.services import audit

router = APIRouter(prefix="/admin/connectors", tags=["integrations"])
ADMIN = Depends(require(Permission.ADMIN))

# Sources with a working importer. Empty until one is built.
AVAILABLE: set[ConnectorKind] = set()


class ConnectorOut(BaseModel):
    kind: ConnectorKind
    status: ConnectorStatus
    detail: str
    connected_at: datetime | None


class ConnectorList(BaseModel):
    items: list[ConnectorOut]


@router.get("", response_model=ConnectorList)
def list_connectors(principal: Principal = ADMIN, db: Session = Depends(get_db)) -> ConnectorList:
    """43: always all five kinds."""
    rows = {
        c.kind: c
        for c in db.scalars(select(Connector).where(Connector.tenant_id == principal.tenant_id))
    }
    items = []
    for kind in ConnectorKind:
        row = rows.get(kind)
        if kind not in AVAILABLE:
            items.append(
                ConnectorOut(
                    kind=kind, status=ConnectorStatus.COMING_SOON, detail="", connected_at=None
                )
            )
        elif row is None:
            items.append(
                ConnectorOut(
                    kind=kind, status=ConnectorStatus.NOT_CONNECTED, detail="", connected_at=None
                )
            )
        else:
            items.append(
                ConnectorOut(
                    kind=kind,
                    status=ConnectorStatus(row.status),
                    detail=row.detail,
                    connected_at=row.connected_at,
                )
            )
    return ConnectorList(items=items)


@router.put("/{kind}", response_model=ConnectorOut)
def connect(
    kind: ConnectorKind, body: dict[str, Any], principal: Principal = ADMIN
) -> ConnectorOut:
    """44: refused until the source's importer exists. Credentials are never returned."""
    raise ApiError(
        400, "connector_not_available", "This document source isn't available yet.", field="kind"
    )


@router.delete("/{kind}", status_code=204)
def disconnect(
    kind: ConnectorKind, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> Response:
    """45: forget stored settings. Evidence already imported stays where it is."""
    removed = db.execute(
        delete(Connector).where(Connector.tenant_id == principal.tenant_id, Connector.kind == kind)
    ).rowcount
    if removed:
        audit.record(db, principal, "connector.removed", "connector", kind)
        db.commit()
    return Response(status_code=204)
