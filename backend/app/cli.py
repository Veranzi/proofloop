"""Operator commands.

Create the first organisation and its admin (they sign in with this email):

    python -m app.cli bootstrap --tenant "Acme Ltd" \
        --admin-email admin@acme.com --admin-name "Ada Admin"
"""

import argparse

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import Membership, ProviderSettings, Tenant, User
from app.db.session import get_engine
from app.enums import Role
from app.ids import new_id

DEFAULT_MODEL = "gemini-2.5-flash"


def bootstrap(db: Session, tenant_name: str, admin_email: str, admin_name: str) -> Tenant:
    email = admin_email.strip().lower()
    tenant = Tenant(id=new_id("ten"), name=tenant_name.strip())
    db.add(tenant)
    user = db.scalar(select(User).where(User.email == email))
    if user is None:
        user = User(id=new_id("u"), email=email, name=admin_name.strip())
        db.add(user)
    db.flush()
    db.add(Membership(id=new_id("mem"), tenant_id=tenant.id, user_id=user.id, role=Role.ADMIN))
    db.add(ProviderSettings(tenant_id=tenant.id, model=DEFAULT_MODEL))
    db.commit()
    return tenant


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    boot = sub.add_parser("bootstrap", help="create an organisation and its first admin")
    boot.add_argument("--tenant", required=True)
    boot.add_argument("--admin-email", required=True)
    boot.add_argument("--admin-name", default="")
    args = parser.parse_args()

    with Session(get_engine()) as db:
        tenant = bootstrap(db, args.tenant, args.admin_email, args.admin_name)
    print(f"Created {tenant.id}; {args.admin_email} is its admin.")  # noqa: T201


if __name__ == "__main__":
    main()
