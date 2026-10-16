"""Profile and session: endpoints 1, 2, 21, 22, 23."""

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.principal import Principal, current_user, require_person
from app.db.models import AuditEvent, Case, Device
from app.db.session import get_db
from app.enums import Role
from app.errors import not_found
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit

router = APIRouter(tags=["me"])


class MeOut(BaseModel):
    id: str
    name: str
    email: str
    role: Role
    tenant_id: str
    phone: str
    job_title: str
    active: bool


class MePatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=40)
    job_title: str | None = Field(default=None, max_length=120)


class DeviceIn(BaseModel):
    token: str = Field(min_length=10, max_length=4096)
    platform: Literal["web", "android", "ios"] = "web"


class DeviceOut(BaseModel):
    id: str
    platform: str


ActivityKind = Literal["evidence_uploaded", "review_completed", "report_generated"]

# Audit actions shown on the dashboard, mapped to the frontend's ActivityKind.
ACTIVITY_ACTIONS: dict[str, ActivityKind] = {
    "evidence.uploaded": "evidence_uploaded",
    "finding.decided": "review_completed",
    "report.requested": "report_generated",
}


class ActivityOut(BaseModel):
    title: str
    case_id: str | None
    case_reference: str | None
    at: datetime
    kind: ActivityKind


def _me(principal: Principal) -> MeOut:
    user = current_user(principal)
    return MeOut(
        id=user.id,
        name=user.name,
        email=user.email,
        role=principal.role or Role.VIEWER,
        tenant_id=principal.tenant_id,
        phone=user.phone,
        job_title=user.job_title,
        active=user.active,
    )


@router.get("/me", response_model=MeOut)
def get_me(principal: Principal = Depends(require_person)) -> MeOut:
    """1: the signed-in user's profile and role."""
    return _me(principal)


@router.patch("/me", response_model=MeOut)
def patch_me(
    body: MePatch,
    principal: Principal = Depends(require_person),
    db: Session = Depends(get_db),
) -> MeOut:
    """21: update your own name, phone and job title. Role and email can't change here."""
    user = current_user(principal)
    changes = body.model_dump(exclude_unset=True, exclude_none=True)
    for name, value in changes.items():
        setattr(user, name, value.strip())
    if changes:
        audit.record(
            db,
            principal,
            "user.profile_updated",
            "user",
            user.id,
            details={"fields": sorted(changes)},
        )
        db.commit()
    return _me(principal)


@router.post("/devices", response_model=DeviceOut, status_code=201)
def register_device(
    body: DeviceIn,
    principal: Principal = Depends(require_person),
    db: Session = Depends(get_db),
) -> DeviceOut:
    """2: register a push-notification token. Registering the same token again is a no-op."""
    user = current_user(principal)
    device = db.scalar(select(Device).where(Device.user_id == user.id, Device.token == body.token))
    if device is None:
        device = Device(id=new_id("dev"), user_id=user.id, token=body.token, platform=body.platform)
        db.add(device)
        db.commit()
    return DeviceOut(id=device.id, platform=device.platform)


@router.delete("/devices/{device_id}", status_code=204)
def remove_device(
    device_id: str,
    principal: Principal = Depends(require_person),
    db: Session = Depends(get_db),
) -> Response:
    """22: forget a push token, e.g. on sign-out. Only your own devices."""
    device = db.get(Device, device_id)
    if device is None or device.user_id != principal.user_id:
        raise not_found("Device")
    db.delete(device)
    db.commit()
    return Response(status_code=204)


@router.get("/me/activity", response_model=Page[ActivityOut])
def my_activity(
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require_person),
    db: Session = Depends(get_db),
) -> Page[ActivityOut]:
    """23: your recent uploads, review decisions and reports, newest first."""
    size = clamp_limit(limit)
    query = after_cursor(
        (
            select(AuditEvent, Case.reference)
            .outerjoin(Case, Case.id == AuditEvent.case_id)
            .where(
                AuditEvent.tenant_id == principal.tenant_id,
                AuditEvent.actor_user_id == principal.user_id,
                AuditEvent.action.in_(ACTIVITY_ACTIONS),
            )
            .order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc())
            .limit(size + 1)
        ),
        AuditEvent.created_at,
        AuditEvent.id,
        cursor,
    )
    rows = db.execute(query).all()
    items = [
        ActivityOut(
            title=str(event.details.get("title", event.action)),
            case_id=event.case_id,
            case_reference=reference,
            at=event.created_at,
            kind=ACTIVITY_ACTIONS[event.action],
        )
        for event, reference in rows[:size]
    ]
    return Page[ActivityOut](
        items=items,
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )
