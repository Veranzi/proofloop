"""Operator commands.

Create the first organisation and its admin (they sign in with this email):

    python -m app.cli bootstrap --tenant "Acme Ltd" \
        --admin-email admin@acme.com --admin-name "Ada Admin"

Invite someone to an existing organisation, or change their role:

    python -m app.cli invite --tenant ten_... --email someone@acme.com --role admin

Remove someone's access everywhere. The user row stays, with its email
cleared, because the append-only audit trail refers to it:

    python -m app.cli remove-user --email someone@acme.com
"""

import argparse

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import ProviderSettings, Tenant, User
from app.db.session import get_engine
from app.enums import Role
from app.ids import new_id
from app.services import users

DEFAULT_MODEL = "gemini-2.5-flash"


def bootstrap(db: Session, tenant_name: str, admin_email: str, admin_name: str) -> Tenant:
    email = users.normalise_email(admin_email)
    tenant = Tenant(id=new_id("ten"), name=tenant_name.strip())
    db.add(tenant)
    db.flush()
    users.invite(db, tenant.id, email, Role.ADMIN, admin_name)
    db.add(ProviderSettings(tenant_id=tenant.id, model=DEFAULT_MODEL))
    db.commit()
    return tenant


def invite(db: Session, tenant_id: str, email: str, role: Role, name: str = "") -> User:
    """Give ``email`` the role in the organisation. They link their account on first sign-in."""
    user = users.invite(db, tenant_id, email, role, name)
    db.commit()
    return user


def remove_user(db: Session, email: str) -> User:
    """Take away all access. The row is kept (audit events point at it) but anonymised."""
    user = db.scalar(select(User).where(User.email == users.normalise_email(email)))
    if user is None:
        raise ValueError(f"No user with email {email}")
    users.anonymise(db, user)
    db.commit()
    return user


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    boot = sub.add_parser("bootstrap", help="create an organisation and its first admin")
    boot.add_argument("--tenant", required=True)
    boot.add_argument("--admin-email", required=True)
    boot.add_argument("--admin-name", default="")
    inv = sub.add_parser("invite", help="invite someone to an organisation or change their role")
    inv.add_argument("--tenant", required=True, help="organisation ID, e.g. ten_...")
    inv.add_argument("--email", required=True)
    inv.add_argument("--role", required=True, choices=[r.value for r in Role])
    inv.add_argument("--name", default="")
    rem = sub.add_parser("remove-user", help="remove someone's access everywhere")
    rem.add_argument("--email", required=True)
    args = parser.parse_args()

    with Session(get_engine()) as db:
        try:
            if args.command == "bootstrap":
                tenant_id = bootstrap(db, args.tenant, args.admin_email, args.admin_name).id
                message = f"Created {tenant_id}; {args.admin_email} is its admin."
            elif args.command == "invite":
                invite(db, args.tenant, args.email, Role(args.role), args.name)
                message = f"Invited {args.email.strip().lower()} to {args.tenant} as {args.role}."
            else:
                remove_user(db, args.email)
                message = f"Removed {args.email.strip().lower()}."
        except ValueError as exc:
            parser.error(str(exc))
    print(message)  # noqa: T201


if __name__ == "__main__":
    main()
