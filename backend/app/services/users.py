"""Inviting people, changing roles and removing access.

Shared by the admin endpoints (24-27) and ``python -m app.cli``.
"""

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.db.models import Case, CaseMember, Device, Membership, Tenant, User
from app.enums import Role
from app.errors import conflict
from app.ids import new_id


def normalise_email(email: str) -> str:
    email = email.strip().lower()
    local, _, domain = email.partition("@")
    if not local or "." not in domain or " " in email:
        raise ValueError(f"Not an email address: {email!r}")
    return email


def active_admins(db: Session, tenant_id: str) -> int:
    return int(
        db.scalar(
            select(func.count())
            .select_from(Membership)
            .join(User, User.id == Membership.user_id)
            .where(
                Membership.tenant_id == tenant_id,
                Membership.role == Role.ADMIN,
                User.active.is_(True),
            )
        )
        or 0
    )


def invite(db: Session, tenant_id: str, email: str, role: Role, name: str = "") -> User:
    """Give ``email`` the role in the organisation. They link their account on first sign-in.

    Doesn't commit, so callers can add an audit event in the same transaction.
    """
    if db.get(Tenant, tenant_id) is None:
        raise ValueError(f"No organisation {tenant_id}")
    email = normalise_email(email)
    user = db.scalar(select(User).where(User.email == email))
    if user is None:
        user = User(id=new_id("u"), email=email, name=name.strip())
        db.add(user)
        db.flush()
    elif name.strip() and not user.name:
        user.name = name.strip()
    user.active = True
    membership = db.scalar(
        select(Membership).where(Membership.tenant_id == tenant_id, Membership.user_id == user.id)
    )
    if membership is None:
        db.add(Membership(id=new_id("mem"), tenant_id=tenant_id, user_id=user.id, role=role))
    else:
        if membership.role == Role.ADMIN and role != Role.ADMIN:
            guard_last_admin(db, tenant_id, user)
        membership.role = role
    db.flush()
    return user


def guard_last_admin(db: Session, tenant_id: str, user: User) -> None:
    """Refuse a change that would leave the organisation without an active admin."""
    membership = db.scalar(
        select(Membership).where(Membership.tenant_id == tenant_id, Membership.user_id == user.id)
    )
    if (
        membership is not None
        and membership.role == Role.ADMIN
        and user.active
        and active_admins(db, tenant_id) <= 1
    ):
        raise conflict("There must always be at least one active admin.")


def remove_from_tenant(db: Session, tenant_id: str, user: User) -> None:
    """Take away access to one organisation. If it was their last, anonymise them."""
    guard_last_admin(db, tenant_id, user)
    db.execute(
        delete(Membership).where(Membership.tenant_id == tenant_id, Membership.user_id == user.id)
    )
    tenant_cases = select(Case.id).where(Case.tenant_id == tenant_id)
    db.execute(
        delete(CaseMember).where(
            CaseMember.user_id == user.id, CaseMember.case_id.in_(tenant_cases)
        )
    )
    remaining = db.scalar(
        select(func.count()).select_from(Membership).where(Membership.user_id == user.id)
    )
    if not remaining:
        anonymise(db, user)


def anonymise(db: Session, user: User) -> None:
    """The row stays (the append-only audit trail refers to it) but can't sign in again."""
    db.execute(delete(Membership).where(Membership.user_id == user.id))
    db.execute(delete(CaseMember).where(CaseMember.user_id == user.id))
    db.execute(delete(Device).where(Device.user_id == user.id))
    user.active = False
    user.firebase_uid = None
    user.email = f"removed+{user.id}@pruflo.invalid"
    user.phone = ""
