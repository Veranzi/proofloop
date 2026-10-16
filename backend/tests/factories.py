"""Small builders for test data. Each returns committed rows (savepoints in tests)."""

from dataclasses import dataclass

from sqlalchemy.orm import Session

from app.auth import api_keys
from app.db.models import ApiKey, Case, CaseMember, Membership, Tenant, User
from app.enums import Role
from app.ids import new_id


@dataclass
class Person:
    user: User
    tenant: Tenant
    role: Role

    @property
    def headers(self) -> dict[str, str]:
        assert self.user.firebase_uid, "invited users have no token yet"
        return {"Authorization": f"Bearer dev:{self.user.firebase_uid}:{self.user.email}"}


class Factory:
    def __init__(self, db: Session) -> None:
        self.db = db

    def tenant(self, name: str = "Acme") -> Tenant:
        tenant = Tenant(id=new_id("ten"), name=name)
        self.db.add(tenant)
        self.db.commit()
        return tenant

    def person(
        self,
        role: Role = Role.INVESTIGATOR,
        tenant: Tenant | None = None,
        *,
        name: str = "Test Person",
        invited_only: bool = False,
        active: bool = True,
    ) -> Person:
        tenant = tenant or self.tenant()
        uid = new_id("fb")
        user = User(
            id=new_id("u"),
            firebase_uid=None if invited_only else uid,
            email=f"{uid}@example.com",
            name=name,
            active=active,
        )
        self.db.add(user)
        self.db.flush()
        self.db.add(Membership(id=new_id("mem"), tenant_id=tenant.id, user_id=user.id, role=role))
        self.db.commit()
        return Person(user=user, tenant=tenant, role=role)

    def case(self, tenant: Tenant, *members: Person, title: str = "Fraud Investigation") -> Case:
        tenant.next_case_number = (tenant.next_case_number or 1) + 1
        case = Case(
            id=new_id("case"),
            tenant_id=tenant.id,
            reference=f"PL-{tenant.next_case_number - 1:03d}",
            title=title,
        )
        self.db.add(case)
        self.db.flush()
        for person in members:
            self.db.add(CaseMember(case_id=case.id, user_id=person.user.id))
        self.db.commit()
        return case

    def api_key(self, tenant: Tenant, *scopes: str, revoked: bool = False) -> tuple[ApiKey, str]:
        from datetime import UTC, datetime

        secret = api_keys.generate_key()
        key = ApiKey(
            id=new_id("key"),
            tenant_id=tenant.id,
            name="test key",
            prefix=api_keys.display_prefix(secret),
            key_hash=api_keys.hash_key(secret),
            scopes=list(scopes),
            revoked_at=datetime.now(UTC) if revoked else None,
        )
        self.db.add(key)
        self.db.commit()
        return key, secret


def key_headers(secret: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}
