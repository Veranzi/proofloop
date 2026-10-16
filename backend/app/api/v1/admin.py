"""Admin: endpoints 24-33 (Docs/API_Contract.md, "Admin").

Admins of an organisation only, never API keys. Everything is audited.
"""

from datetime import datetime
from typing import Any, Literal

from fastapi import APIRouter, Depends, Query, Response
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import or_, select
from sqlalchemy.orm import Session, aliased

from app.api.v1.cases import PersonRef
from app.auth.permissions import Permission
from app.auth.principal import Principal, load_case, require
from app.db.models import AuditEvent, CaseMember, Customer, Membership, User
from app.db.session import get_db
from app.enums import Role
from app.errors import bad_request, not_found
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit, users

router = APIRouter(prefix="/admin", tags=["admin"])
ADMIN = Depends(require(Permission.ADMIN))


# Users (24-27) -----------------------------------------------------------------


class UserOut(BaseModel):
    id: str
    name: str
    email: str
    role: Role
    active: bool
    signed_in: bool  # False until they first sign in and their Firebase account is linked
    created_at: datetime


class UserIn(BaseModel):
    email: EmailStr
    name: str = Field(default="", max_length=200)
    role: Role


class UserPatch(BaseModel):
    role: Role | None = None
    active: bool | None = None
    name: str | None = Field(default=None, min_length=1, max_length=200)


def _user_out(user: User, membership: Membership) -> UserOut:
    return UserOut(
        id=user.id,
        name=user.name,
        email=user.email,
        role=Role(membership.role),
        active=user.active,
        signed_in=user.firebase_uid is not None,
        created_at=membership.created_at,
    )


def _member(db: Session, tenant_id: str, user_id: str) -> tuple[User, Membership]:
    row = db.execute(
        select(User, Membership)
        .join(Membership, Membership.user_id == User.id)
        .where(User.id == user_id, Membership.tenant_id == tenant_id)
    ).first()
    if row is None:
        raise not_found("User")
    return row[0], row[1]


@router.get("/users", response_model=Page[UserOut])
def list_users(
    q: str | None = Query(default=None, max_length=100),
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> Page[UserOut]:
    """24"""
    size = clamp_limit(limit)
    query = (
        select(User, Membership)
        .join(Membership, Membership.user_id == User.id)
        .where(Membership.tenant_id == principal.tenant_id)
    )
    if q and q.strip():
        like = f"%{q.strip()}%"
        query = query.where(or_(User.name.ilike(like), User.email.ilike(like)))
    query = after_cursor(
        query.order_by(Membership.created_at.desc(), Membership.id.desc()).limit(size + 1),
        Membership.created_at,
        Membership.id,
        cursor,
    )
    rows = db.execute(query).all()
    return Page[UserOut](
        items=[_user_out(u, m) for u, m in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda r: (r[1].created_at, r[1].id)),
    )


@router.post("/users", response_model=UserOut, status_code=201)
def invite_user(
    body: UserIn, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> UserOut:
    """25: no email is sent; they sign in with this address and are linked on first sign-in."""
    try:
        user = users.invite(db, principal.tenant_id, str(body.email), body.role, body.name)
    except ValueError as exc:
        raise bad_request(str(exc), field="email") from exc
    audit.record(
        db,
        principal,
        "user.invited",
        "user",
        user.id,
        details={"email": user.email, "role": body.role},
    )
    db.commit()
    return _user_out(*_member(db, principal.tenant_id, user.id))


@router.patch("/users/{user_id}", response_model=UserOut)
def update_user(
    user_id: str, body: UserPatch, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> UserOut:
    """26: change role, enable or disable, or fix the name."""
    user, membership = _member(db, principal.tenant_id, user_id)
    changes = body.model_dump(exclude_unset=True, exclude_none=True)
    demoting = "role" in changes and membership.role == Role.ADMIN and changes["role"] != Role.ADMIN
    disabling = changes.get("active") is False and user.active
    if demoting or disabling:
        users.guard_last_admin(db, principal.tenant_id, user)
    if "role" in changes:
        membership.role = changes["role"]
    if "active" in changes:
        user.active = changes["active"]
    if "name" in changes:
        user.name = changes["name"].strip()
    if changes:
        audit.record(
            db,
            principal,
            "user.updated",
            "user",
            user.id,
            details={k: str(v) for k, v in changes.items()},
        )
        db.commit()
    return _user_out(user, membership)


@router.delete("/users/{user_id}", status_code=204)
def remove_user(
    user_id: str, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> Response:
    """27: remove them from this organisation."""
    user, _ = _member(db, principal.tenant_id, user_id)
    users.remove_from_tenant(db, principal.tenant_id, user)
    audit.record(db, principal, "user.removed", "user", user.id)
    db.commit()
    return Response(status_code=204)


# Customers (28-30) ---------------------------------------------------------------


class CustomerOut(BaseModel):
    id: str
    name: str
    contact_email: str
    created_at: datetime


class CustomerIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    contact_email: EmailStr | Literal[""] = ""


class CustomerPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    contact_email: EmailStr | Literal[""] | None = None


def _customer_out(c: Customer) -> CustomerOut:
    return CustomerOut(id=c.id, name=c.name, contact_email=c.contact_email, created_at=c.created_at)


@router.get("/customers", response_model=Page[CustomerOut])
def list_customers(
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> Page[CustomerOut]:
    """28"""
    size = clamp_limit(limit)
    rows = db.scalars(
        after_cursor(
            select(Customer)
            .where(Customer.tenant_id == principal.tenant_id)
            .order_by(Customer.created_at.desc(), Customer.id.desc())
            .limit(size + 1),
            Customer.created_at,
            Customer.id,
            cursor,
        )
    ).all()
    return Page[CustomerOut](
        items=[_customer_out(c) for c in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda c: (c.created_at, c.id)),
    )


@router.post("/customers", response_model=CustomerOut, status_code=201)
def create_customer(
    body: CustomerIn, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> CustomerOut:
    """29"""
    customer = Customer(
        id=new_id("cus"),
        tenant_id=principal.tenant_id,
        name=body.name.strip(),
        contact_email=str(body.contact_email).lower(),
    )
    db.add(customer)
    db.flush()
    audit.record(
        db, principal, "customer.created", "customer", customer.id, details={"name": customer.name}
    )
    db.commit()
    db.refresh(customer)
    return _customer_out(customer)


@router.patch("/customers/{customer_id}", response_model=CustomerOut)
def update_customer(
    customer_id: str,
    body: CustomerPatch,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> CustomerOut:
    """30"""
    customer = db.get(Customer, customer_id)
    if customer is None or customer.tenant_id != principal.tenant_id:
        raise not_found("Customer")
    changes = body.model_dump(exclude_unset=True, exclude_none=True)
    if "name" in changes:
        customer.name = changes["name"].strip()
    if "contact_email" in changes:
        customer.contact_email = str(changes["contact_email"]).lower()
    if changes:
        audit.record(
            db,
            principal,
            "customer.updated",
            "customer",
            customer.id,
            details={"fields": sorted(changes)},
        )
        db.commit()
    return _customer_out(customer)


# Case members (31-32) ------------------------------------------------------------


class MemberOut(BaseModel):
    uid: str
    name: str
    email: str
    role: Role


class MembersIn(BaseModel):
    user_ids: list[str] = Field(max_length=200)


class MembersOut(BaseModel):
    items: list[MemberOut]


def _members(db: Session, tenant_id: str, case_id: str) -> MembersOut:
    rows = db.execute(
        select(User, Membership)
        .join(CaseMember, CaseMember.user_id == User.id)
        .join(Membership, (Membership.user_id == User.id) & (Membership.tenant_id == tenant_id))
        .where(CaseMember.case_id == case_id)
        .order_by(User.name, User.email)
    ).all()
    return MembersOut(
        items=[MemberOut(uid=u.id, name=u.name, email=u.email, role=Role(m.role)) for u, m in rows]
    )


@router.get("/cases/{case_id}/members", response_model=MembersOut)
def list_members(
    case_id: str, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> MembersOut:
    """31"""
    case = load_case(db, principal, case_id)
    return _members(db, principal.tenant_id, case.id)


@router.put("/cases/{case_id}/members", response_model=MembersOut)
def set_members(
    case_id: str, body: MembersIn, principal: Principal = ADMIN, db: Session = Depends(get_db)
) -> MembersOut:
    """32: replace the case's members with exactly these users from the organisation."""
    case = load_case(db, principal, case_id)
    wanted = set(body.user_ids)
    in_tenant = set(
        db.scalars(
            select(Membership.user_id).where(
                Membership.tenant_id == principal.tenant_id, Membership.user_id.in_(wanted)
            )
        )
    )
    unknown = wanted - in_tenant
    if unknown:
        raise bad_request(f"Not in your organisation: {', '.join(sorted(unknown))}", "user_ids")
    current = set(db.scalars(select(CaseMember.user_id).where(CaseMember.case_id == case.id)))
    for user_id in current - wanted:
        member = db.get(CaseMember, (case.id, user_id))
        if member is not None:
            db.delete(member)
    for user_id in wanted - current:
        db.add(CaseMember(case_id=case.id, user_id=user_id, added_by=principal.user_id))
    if current != wanted:
        audit.record(
            db,
            principal,
            "case.members_changed",
            "case",
            case.id,
            case_id=case.id,
            details={"added": sorted(wanted - current), "removed": sorted(current - wanted)},
        )
        db.commit()
    return _members(db, principal.tenant_id, case.id)


# Audit log (33) ------------------------------------------------------------------


class AuditOut(BaseModel):
    id: str
    action: str
    at: datetime
    actor_type: Literal["person", "api_key", "system"]
    actor: PersonRef | None
    target_type: str
    target_id: str
    case_id: str | None
    details: dict[str, Any]


@router.get("/audit", response_model=Page[AuditOut])
def audit_log(
    action: str | None = Query(default=None, max_length=60),
    case_id: str | None = Query(default=None, max_length=40),
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = ADMIN,
    db: Session = Depends(get_db),
) -> Page[AuditOut]:
    """33: everything that happened in the organisation, newest first."""
    size = clamp_limit(limit)
    actor = aliased(User)
    query = (
        select(AuditEvent, actor)
        .outerjoin(actor, actor.id == AuditEvent.actor_user_id)
        .where(AuditEvent.tenant_id == principal.tenant_id)
    )
    if action:
        query = query.where(AuditEvent.action == action)
    if case_id:
        query = query.where(AuditEvent.case_id == case_id)
    rows = db.execute(
        after_cursor(
            query.order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc()).limit(size + 1),
            AuditEvent.created_at,
            AuditEvent.id,
            cursor,
        )
    ).all()
    items = [
        AuditOut(
            id=e.id,
            action=e.action,
            at=e.created_at,
            actor_type="person" if u else ("api_key" if e.actor_api_key_id else "system"),
            actor=PersonRef(uid=u.id, name=u.name) if u else None,
            target_type=e.target_type,
            target_id=e.target_id,
            case_id=e.case_id,
            details=e.details,
        )
        for e, u in rows[:size]
    ]
    return Page[AuditOut](
        items=items,
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )
