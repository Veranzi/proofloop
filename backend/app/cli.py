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

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.db.models import CaseMember, Device, Membership, ProviderSettings, Tenant, User
from app.db.session import get_engine
from app.enums import Role
from app.ids import new_id

DEFAULT_MODEL = "gemini-2.5-flash"


def _normalise(email: str) -> str:
    email = email.strip().lower()
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError(f"Not an email address: {email!r}")
    return email


def bootstrap(db: Session, tenant_name: str, admin_email: str, admin_name: str) -> Tenant:
    email = _normalise(admin_email)
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


def invite(db: Session, tenant_id: str, email: str, role: Role, name: str = "") -> User:
    """Give ``email`` the role in the organisation. They link their account on first sign-in."""
    if db.get(Tenant, tenant_id) is None:
        raise ValueError(f"No organisation {tenant_id}")
    email = _normalise(email)
    user = db.scalar(select(User).where(User.email == email))
    if user is None:
        user = User(id=new_id("u"), email=email, name=name.strip())
        db.add(user)
        db.flush()
    user.active = True
    membership = db.scalar(
        select(Membership).where(Membership.tenant_id == tenant_id, Membership.user_id == user.id)
    )
    if membership is None:
        db.add(Membership(id=new_id("mem"), tenant_id=tenant_id, user_id=user.id, role=role))
    else:
        membership.role = role
    db.commit()
    return user


def remove_user(db: Session, email: str) -> User:
    """Take away all access. The row is kept (audit events point at it) but anonymised."""
    user = db.scalar(select(User).where(User.email == _normalise(email)))
    if user is None:
        raise ValueError(f"No user with email {email}")
    db.execute(delete(Membership).where(Membership.user_id == user.id))
    db.execute(delete(CaseMember).where(CaseMember.user_id == user.id))
    db.execute(delete(Device).where(Device.user_id == user.id))
    user.active = False
    user.firebase_uid = None
    user.email = f"removed+{user.id}@pruflo.invalid"
    user.phone = ""
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
