"""Resolve the caller on every request and check what they may do.

Routes depend on ``require(Permission.X)``; case routes also call
``load_case`` so a caller only ever sees cases they're allowed to see.
"""

from collections.abc import Callable
from dataclasses import dataclass, field

from fastapi import Depends, Header
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import api_keys
from app.auth.firebase import FirebaseIdentity, verify_app_check, verify_id_token
from app.auth.permissions import ROLE_PERMISSIONS, Permission, permissions_for_scopes
from app.db.models import ApiKey, Case, CaseMember, Membership, User
from app.db.session import get_db
from app.enums import Role
from app.errors import ApiError, forbidden, not_found, unauthorized


@dataclass(frozen=True)
class Principal:
    tenant_id: str
    permissions: frozenset[Permission]
    user: User | None = None
    role: Role | None = None
    api_key: ApiKey | None = None
    scopes: tuple[str, ...] = field(default=())

    @property
    def is_person(self) -> bool:
        return self.user is not None

    @property
    def user_id(self) -> str | None:
        return self.user.id if self.user else None

    @property
    def api_key_id(self) -> str | None:
        return self.api_key.id if self.api_key else None

    def can(self, permission: Permission) -> bool:
        return permission in self.permissions


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise unauthorized()
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise unauthorized()
    return token


def _find_user(db: Session, identity: FirebaseIdentity) -> User:
    user = db.scalar(select(User).where(User.firebase_uid == identity.uid))
    if user is None and identity.email and identity.email_verified:
        # First sign-in of an invited user: link the Firebase account by verified email.
        user = db.scalar(
            select(User).where(User.email == identity.email, User.firebase_uid.is_(None))
        )
        if user is not None:
            user.firebase_uid = identity.uid
            if not user.name and identity.name:
                user.name = identity.name
            db.commit()
    if user is None:
        raise ApiError(403, "not_invited", "This account hasn't been invited to Pruflo.")
    if not user.active:
        raise ApiError(403, "account_disabled", "This account has been disabled.")
    return user


def _membership(db: Session, user: User, tenant_id: str | None) -> Membership:
    query = select(Membership).where(Membership.user_id == user.id)
    if tenant_id:
        query = query.where(Membership.tenant_id == tenant_id)
    memberships = list(db.scalars(query.limit(2)))
    if not memberships:
        raise ApiError(403, "not_invited", "This account has no access to this organisation.")
    if len(memberships) > 1:
        raise ApiError(400, "tenant_required", "Send X-Pruflo-Tenant to choose an organisation.")
    return memberships[0]


def get_principal(
    authorization: str | None = Header(default=None),
    app_check_token: str | None = Header(default=None, alias="X-Firebase-AppCheck"),
    tenant_header: str | None = Header(default=None, alias="X-Pruflo-Tenant"),
    db: Session = Depends(get_db),
) -> Principal:
    token = _bearer(authorization)
    if api_keys.is_api_key(token):
        key = api_keys.authenticate_key(db, token)
        return Principal(
            tenant_id=key.tenant_id,
            permissions=permissions_for_scopes(key.scopes),
            api_key=key,
            scopes=tuple(key.scopes),
        )
    verify_app_check(app_check_token)
    user = _find_user(db, verify_id_token(token))
    membership = _membership(db, user, tenant_header)
    role = Role(membership.role)
    return Principal(
        tenant_id=membership.tenant_id,
        permissions=ROLE_PERMISSIONS[role],
        user=user,
        role=role,
    )


def require(*needed: Permission) -> Callable[..., Principal]:
    """Dependency: the caller must hold every listed permission."""

    def dependency(principal: Principal = Depends(get_principal)) -> Principal:
        if any(p in (Permission.DECIDE, Permission.ADMIN) for p in needed) and (
            not principal.is_person
        ):
            raise forbidden("API keys can't do this. A signed-in person must.")
        if not all(principal.can(p) for p in needed):
            raise forbidden()
        return principal

    return dependency


def require_person(principal: Principal = Depends(get_principal)) -> Principal:
    if not principal.is_person:
        raise forbidden("This endpoint is for signed-in people only.")
    return principal


def current_user(principal: Principal) -> User:
    if principal.user is None:  # guarded by require_person
        raise forbidden("This endpoint is for signed-in people only.")
    return principal.user


def can_see_case(db: Session, principal: Principal, case: Case) -> bool:
    if case.tenant_id != principal.tenant_id:
        return False
    # Admins and API keys act across their tenant; everyone else needs membership.
    if principal.api_key is not None or principal.role == Role.ADMIN:
        return True
    return (
        db.scalar(
            select(CaseMember.case_id).where(
                CaseMember.case_id == case.id, CaseMember.user_id == principal.user_id
            )
        )
        is not None
    )


def load_case(db: Session, principal: Principal, case_id: str) -> Case:
    """Return the case or 404 — never reveal that a case exists to someone who can't see it."""
    case = db.get(Case, case_id)
    if case is None or not can_see_case(db, principal, case):
        raise not_found("Case")
    return case
