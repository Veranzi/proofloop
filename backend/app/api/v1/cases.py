"""Cases: endpoints 3, 4, 5, 6 and 16 (timeline)."""

from datetime import datetime
from typing import Any, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import Select, or_, select
from sqlalchemy.orm import Session, aliased

from app.auth.permissions import Permission
from app.auth.principal import Principal, load_case, require
from app.db.models import AuditEvent, Case, CaseMember, Customer, Membership, User
from app.db.session import get_db
from app.enums import CaseStatus, Priority, Role
from app.errors import bad_request, conflict
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit
from app.services import cases as case_service

router = APIRouter(prefix="/cases", tags=["cases"])


class PersonRef(BaseModel):
    uid: str
    name: str


class CaseOut(BaseModel):
    id: str
    reference: str
    title: str
    category: str
    description: str
    status: CaseStatus
    priority: Priority
    customer_id: str | None
    customer_name: str | None
    assigned_to: PersonRef | None
    created_at: datetime
    updated_at: datetime
    version: int


class _CaseFields(BaseModel):
    @field_validator("title", "category", "description", check_fields=False)
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return v.strip() if isinstance(v, str) else v


class CaseIn(_CaseFields):
    title: str = Field(min_length=1, max_length=200)
    category: str = Field(default="", max_length=80)
    description: str = Field(default="", max_length=5000)
    priority: Priority = Priority.MEDIUM
    assigned_to: str | None = None  # user ID in the same organisation
    customer_id: str | None = None


class CasePatch(_CaseFields):
    """Status is not editable: it follows the evidence and review (see services/cases.py)."""

    title: str | None = Field(default=None, min_length=1, max_length=200)
    category: str | None = Field(default=None, max_length=80)
    description: str | None = Field(default=None, max_length=5000)
    priority: Priority | None = None
    assigned_to: str | None = None
    customer_id: str | None = None
    # Optional optimistic lock: send the version you edited, get 409 if it changed.
    version: int | None = None


class TimelineItem(BaseModel):
    id: str
    action: str
    at: datetime
    actor_type: Literal["person", "api_key", "system"]
    actor: PersonRef | None
    details: dict[str, Any]


def _out(case: Case, assignee: User | None, customer_name: str | None = None) -> CaseOut:
    return CaseOut(
        id=case.id,
        reference=case.reference,
        title=case.title,
        category=case.category,
        description=case.description,
        status=CaseStatus(case.status),
        priority=Priority(case.priority),
        customer_id=case.customer_id,
        customer_name=customer_name,
        assigned_to=PersonRef(uid=assignee.id, name=assignee.name) if assignee else None,
        created_at=case.created_at,
        updated_at=case.updated_at,
        version=case.version,
    )


def _customer_name(db: Session, case: Case) -> str | None:
    customer = db.get(Customer, case.customer_id) if case.customer_id else None
    return customer.name if customer else None


def _check_assignee(db: Session, tenant_id: str, user_id: str) -> User:
    user = db.scalar(
        select(User)
        .join(Membership, Membership.user_id == User.id)
        .where(User.id == user_id, Membership.tenant_id == tenant_id, User.active.is_(True))
    )
    if user is None:
        raise bad_request("No active user with that ID in your organisation.", field="assigned_to")
    return user


def _check_customer(db: Session, tenant_id: str, customer_id: str) -> None:
    customer = db.get(Customer, customer_id)
    if customer is None or customer.tenant_id != tenant_id:
        raise bad_request("No customer with that ID in your organisation.", field="customer_id")


def visible_cases(principal: Principal) -> Select[tuple[Case]]:
    query = select(Case).where(Case.tenant_id == principal.tenant_id)
    if principal.api_key is None and principal.role != Role.ADMIN:
        query = query.join(
            CaseMember,
            (CaseMember.case_id == Case.id) & (CaseMember.user_id == principal.user_id),
        )
    return query


@router.get("", response_model=Page[CaseOut])
def list_cases(
    status: CaseStatus | None = None,
    priority: Priority | None = None,
    q: str | None = Query(default=None, max_length=100),
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> Page[CaseOut]:
    """3: cases you can see, newest first. Filter by status, priority or text."""
    size = clamp_limit(limit)
    assignee = aliased(User)
    query = (
        visible_cases(principal)
        .add_columns(assignee, Customer.name)
        .outerjoin(assignee, assignee.id == Case.assigned_to)
        .outerjoin(Customer, Customer.id == Case.customer_id)
    )
    if status:
        query = query.where(Case.status == status)
    if priority:
        query = query.where(Case.priority == priority)
    if q and q.strip():
        like = f"%{q.strip()}%"
        query = query.where(or_(Case.title.ilike(like), Case.reference.ilike(like)))
    query = after_cursor(
        query.order_by(Case.created_at.desc(), Case.id.desc()).limit(size + 1),
        Case.created_at,
        Case.id,
        cursor,
    )
    rows = db.execute(query).all()
    return Page[CaseOut](
        items=[_out(case, user, customer) for case, user, customer in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )


@router.post("", response_model=CaseOut, status_code=201)
def create_case(
    body: CaseIn,
    principal: Principal = Depends(require(Permission.EDIT_CASES)),
    db: Session = Depends(get_db),
) -> CaseOut:
    """4: new cases start as awaiting_evidence. The creator and assignee become members."""
    assignee = (
        _check_assignee(db, principal.tenant_id, body.assigned_to) if body.assigned_to else None
    )
    if body.customer_id:
        _check_customer(db, principal.tenant_id, body.customer_id)
    case = Case(
        id=new_id("case"),
        tenant_id=principal.tenant_id,
        reference=case_service.next_reference(db, principal.tenant_id),
        title=body.title,
        category=body.category,
        description=body.description,
        priority=body.priority,
        status=CaseStatus.AWAITING_EVIDENCE,
        assigned_to=assignee.id if assignee else None,
        customer_id=body.customer_id,
        created_by=principal.user_id,
    )
    db.add(case)
    db.flush()
    for user_id in dict.fromkeys(u for u in (principal.user_id, case.assigned_to) if u):
        case_service.add_member(db, case.id, user_id, principal.user_id)
    if case.assigned_to:
        case_service.notify_assignee(db, case, principal)
    audit.record(
        db,
        principal,
        "case.created",
        "case",
        case.id,
        case_id=case.id,
        details={"reference": case.reference, "title": case.title},
    )
    db.commit()
    db.refresh(case)
    return _out(case, assignee, _customer_name(db, case))


@router.get("/{case_id}", response_model=CaseOut)
def get_case(
    case_id: str,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> CaseOut:
    """5"""
    case = load_case(db, principal, case_id)
    return _out(
        case,
        db.get(User, case.assigned_to) if case.assigned_to else None,
        _customer_name(db, case),
    )


@router.patch("/{case_id}", response_model=CaseOut)
def update_case(
    case_id: str,
    body: CasePatch,
    principal: Principal = Depends(require(Permission.EDIT_CASES)),
    db: Session = Depends(get_db),
) -> CaseOut:
    """6: edit title, category, description, priority, assignee or customer."""
    case = load_case(db, principal, case_id)
    if body.version is not None and body.version != case.version:
        raise conflict("This case was changed by someone else. Reload and try again.")
    changes = body.model_dump(exclude_unset=True, exclude={"version"})
    if "title" in changes and changes["title"] is None:
        raise bad_request("title can't be empty", field="title")
    if changes.get("assigned_to"):
        _check_assignee(db, principal.tenant_id, changes["assigned_to"])
    if changes.get("customer_id"):
        _check_customer(db, principal.tenant_id, changes["customer_id"])
    changed = {k: v for k, v in changes.items() if getattr(case, k) != v}
    if changed:
        for name, value in changed.items():
            setattr(case, name, value)
        case.version += 1
        if changed.get("assigned_to"):
            case_service.add_member(db, case.id, changed["assigned_to"], principal.user_id)
            case_service.notify_assignee(db, case, principal)
        audit.record(
            db,
            principal,
            "case.updated",
            "case",
            case.id,
            case_id=case.id,
            details={"fields": sorted(changed)},
        )
        db.commit()
        db.refresh(case)
    return _out(
        case,
        db.get(User, case.assigned_to) if case.assigned_to else None,
        _customer_name(db, case),
    )


@router.get("/{case_id}/timeline", response_model=Page[TimelineItem])
def timeline(
    case_id: str,
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> Page[TimelineItem]:
    """16: everything that happened to the case, newest first, from the audit trail."""
    case = load_case(db, principal, case_id)
    size = clamp_limit(limit)
    query = after_cursor(
        select(AuditEvent, User)
        .outerjoin(User, User.id == AuditEvent.actor_user_id)
        .where(AuditEvent.case_id == case.id)
        .order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc())
        .limit(size + 1),
        AuditEvent.created_at,
        AuditEvent.id,
        cursor,
    )
    rows = db.execute(query).all()
    items = [
        TimelineItem(
            id=event.id,
            action=event.action,
            at=event.created_at,
            actor_type="person" if user else ("api_key" if event.actor_api_key_id else "system"),
            actor=PersonRef(uid=user.id, name=user.name) if user else None,
            details=event.details,
        )
        for event, user in rows[:size]
    ]
    return Page[TimelineItem](
        items=items,
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )
