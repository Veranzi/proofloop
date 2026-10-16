from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import api_keys
from app.config import get_settings
from app.db.models import ApiKey, AuditEvent, User
from app.enums import Role
from tests.factories import Factory, key_headers


def _error_code(res: object) -> str:
    return res.json()["error"]["code"]  # type: ignore[attr-defined, no-any-return]


# Who is calling ------------------------------------------------------------------


def test_missing_or_malformed_token_is_401(client: TestClient) -> None:
    assert client.get("/v1/me").status_code == 401
    res = client.get("/v1/me", headers={"Authorization": "Basic abc"})
    assert res.status_code == 401
    assert _error_code(res) == "unauthenticated"


def test_uninvited_account_is_403(client: TestClient) -> None:
    res = client.get("/v1/me", headers={"Authorization": "Bearer dev:stranger:x@example.com"})
    assert res.status_code == 403
    assert _error_code(res) == "not_invited"


def test_invited_user_is_linked_on_first_sign_in(
    client: TestClient, make: Factory, db: Session
) -> None:
    person = make.person(Role.REVIEWER, invited_only=True)
    res = client.get("/v1/me", headers={"Authorization": f"Bearer dev:fb_new:{person.user.email}"})
    assert res.status_code == 200
    assert res.json()["role"] == "reviewer"
    db.refresh(person.user)
    assert person.user.firebase_uid == "fb_new"


def test_disabled_user_is_403(client: TestClient, make: Factory) -> None:
    person = make.person(active=False)
    res = client.get("/v1/me", headers=person.headers)
    assert res.status_code == 403
    assert _error_code(res) == "account_disabled"


def test_dev_tokens_are_refused_outside_local_and_test(
    client: TestClient, make: Factory, monkeypatch: object
) -> None:
    person = make.person()
    settings = get_settings()
    original = settings.env
    settings.env = "prod"
    try:
        # A dev token is not a Firebase token; it must never be accepted in prod.
        res = client.get("/v1/me", headers=person.headers)
    finally:
        settings.env = original
    assert res.status_code == 401


# Profile and devices (1, 2, 21, 22) ----------------------------------------------


def test_get_and_patch_me(client: TestClient, make: Factory, db: Session) -> None:
    person = make.person(Role.INVESTIGATOR, name="Sarah Johnson")
    me = client.get("/v1/me", headers=person.headers).json()
    assert me["name"] == "Sarah Johnson"
    assert me["role"] == "investigator"
    assert me["tenant_id"] == person.tenant.id

    res = client.patch(
        "/v1/me",
        headers=person.headers,
        json={"job_title": " Analyst ", "role": "admin", "email": "x@evil.com"},
    )
    assert res.status_code == 200
    assert res.json()["job_title"] == "Analyst"
    assert res.json()["role"] == "investigator"  # role and email can't be changed here
    assert res.json()["email"] == person.user.email
    assert db.scalar(select(AuditEvent).where(AuditEvent.action == "user.profile_updated"))


def test_devices_register_once_and_only_owner_can_remove(client: TestClient, make: Factory) -> None:
    alice, bob = make.person(), make.person()
    body = {"token": "fcm-token-abcdef", "platform": "android"}
    first = client.post("/v1/devices", headers=alice.headers, json=body)
    again = client.post("/v1/devices", headers=alice.headers, json=body)
    assert first.status_code == again.status_code == 201
    assert first.json()["id"] == again.json()["id"]

    device_id = first.json()["id"]
    assert client.delete(f"/v1/devices/{device_id}", headers=bob.headers).status_code == 404
    assert client.delete(f"/v1/devices/{device_id}", headers=alice.headers).status_code == 204


# API keys (34-36) and what keys may do ---------------------------------------------


def test_admin_creates_key_and_secret_is_shown_once(
    client: TestClient, make: Factory, db: Session
) -> None:
    admin = make.person(Role.ADMIN)
    res = client.post(
        "/v1/admin/api-keys",
        headers=admin.headers,
        json={"name": "Odoo sync job", "scopes": ["cases:write", "evidence:write"]},
    )
    assert res.status_code == 201
    created = res.json()
    secret = created["secret"]
    assert secret.startswith("pf_live_") and len(secret) == len("pf_live_") + 32
    assert created["prefix"] == secret[:12]
    assert created["created_by"] == {"uid": admin.user.id, "name": admin.user.name}

    stored = db.get(ApiKey, created["id"])
    assert stored is not None and stored.key_hash == api_keys.hash_key(secret)
    assert secret not in str(stored.__dict__)

    listed = client.get("/v1/admin/api-keys", headers=admin.headers).json()
    assert [k["id"] for k in listed["items"]] == [created["id"]]
    assert "secret" not in listed["items"][0]


def test_key_validation(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    for body in (
        {"name": "x", "scopes": []},
        {"name": "x", "scopes": ["everything"]},
        {"name": "   ", "scopes": ["cases:read"]},
        {"name": "x" * 81, "scopes": ["cases:read"]},
    ):
        res = client.post("/v1/admin/api-keys", headers=admin.headers, json=body)
        assert res.status_code == 400, body


def test_only_admins_manage_keys(client: TestClient, make: Factory) -> None:
    for role in (Role.INVESTIGATOR, Role.REVIEWER, Role.VIEWER):
        person = make.person(role)
        assert client.get("/v1/admin/api-keys", headers=person.headers).status_code == 403


def test_keys_cannot_use_admin_or_person_routes(client: TestClient, make: Factory) -> None:
    tenant = make.tenant()
    _, secret = make.api_key(tenant, "cases:read", "cases:write", "findings:read")
    assert client.get("/v1/admin/api-keys", headers=key_headers(secret)).status_code == 403
    assert client.get("/v1/me", headers=key_headers(secret)).status_code == 403


def test_revoked_or_unknown_key_is_401(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    key, secret = make.api_key(admin.tenant, "cases:read")
    assert client.delete(f"/v1/admin/api-keys/{key.id}", headers=admin.headers).status_code == 204
    assert client.get("/v1/me", headers=key_headers(secret)).status_code == 401
    unknown = api_keys.generate_key()
    assert client.get("/v1/me", headers=key_headers(unknown)).status_code == 401


def test_admins_cannot_touch_other_tenants_keys(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    other_key, _ = make.api_key(make.tenant("Other"), "cases:read")
    res = client.delete(f"/v1/admin/api-keys/{other_key.id}", headers=admin.headers)
    assert res.status_code == 404


def test_key_use_updates_last_used_and_is_rate_limited(
    client: TestClient, make: Factory, db: Session
) -> None:
    key, secret = make.api_key(make.tenant(), "cases:read")
    original_limit = api_keys.rate_limiter.limit
    api_keys.rate_limiter.limit = 2
    try:
        client.get("/v1/me", headers=key_headers(secret))
        client.get("/v1/me", headers=key_headers(secret))
        limited = client.get("/v1/me", headers=key_headers(secret))
    finally:
        api_keys.rate_limiter.limit = original_limit
    assert limited.status_code == 429
    assert int(limited.headers["Retry-After"]) >= 1
    db.refresh(key)
    assert key.last_used_at is not None


def test_activity_lists_only_my_dashboard_actions(client: TestClient, make: Factory) -> None:
    from app.auth.permissions import ROLE_PERMISSIONS
    from app.auth.principal import Principal
    from app.services import audit

    person = make.person(Role.INVESTIGATOR)
    case = make.case(person.tenant, person)
    principal = Principal(
        tenant_id=person.tenant.id,
        permissions=ROLE_PERMISSIONS[Role.INVESTIGATOR],
        user=person.user,
        role=Role.INVESTIGATOR,
    )
    db = make.db
    for i in range(3):
        audit.record(
            db,
            principal,
            "evidence.uploaded",
            "evidence",
            f"evd_{i}",
            case_id=case.id,
            details={"title": f"Uploaded file {i}"},
        )
    audit.record(db, principal, "user.profile_updated", "user", person.user.id)
    db.commit()

    first = client.get("/v1/me/activity?limit=2", headers=person.headers).json()
    assert len(first["items"]) == 2
    assert first["items"][0]["kind"] == "evidence_uploaded"
    assert first["items"][0]["case_reference"] == case.reference
    second = client.get(
        f"/v1/me/activity?limit=2&cursor={first['next_cursor']}", headers=person.headers
    ).json()
    assert len(second["items"]) == 1 and second["next_cursor"] is None
    titles = {i["title"] for i in first["items"] + second["items"]}
    assert titles == {"Uploaded file 0", "Uploaded file 1", "Uploaded file 2"}


def test_bootstrap_creates_tenant_and_admin(db: Session) -> None:
    from app.cli import bootstrap

    tenant = bootstrap(db, "Acme Ltd", "Admin@Acme.com", "Ada")
    user = db.scalar(select(User).where(User.email == "admin@acme.com"))
    assert user is not None and user.firebase_uid is None
    assert tenant.name == "Acme Ltd"


def test_bootstrap_cli_prints_tenant(capsys: object, monkeypatch: object) -> None:
    """Regression: the CLI read the tenant after its session had closed."""
    import sys

    from sqlalchemy import create_engine

    from app import cli
    from tests.conftest import TEST_URL

    engine = create_engine(TEST_URL)
    monkeypatch.setattr(cli, "get_engine", lambda: engine)  # type: ignore[attr-defined]
    monkeypatch.setattr(  # type: ignore[attr-defined]
        sys, "argv", ["cli", "bootstrap", "--tenant", "CLI Ltd", "--admin-email", "cli@example.com"]
    )
    try:
        cli.main()
    finally:
        with engine.begin() as conn:  # this test commits for real, so clean up
            from sqlalchemy import text

            conn.execute(
                text(
                    "DELETE FROM memberships WHERE user_id IN "
                    "(SELECT id FROM users WHERE email = 'cli@example.com')"
                )
            )
            conn.execute(
                text(
                    "DELETE FROM provider_settings WHERE tenant_id IN "
                    "(SELECT id FROM tenants WHERE name = 'CLI Ltd')"
                )
            )
            conn.execute(text("DELETE FROM users WHERE email = 'cli@example.com'"))
            conn.execute(text("DELETE FROM tenants WHERE name = 'CLI Ltd'"))
        engine.dispose()
    assert "is its admin" in capsys.readouterr().out  # type: ignore[attr-defined]


def test_invite_then_sign_in_as_admin(client: TestClient, make: Factory, db: Session) -> None:
    from app.cli import invite

    tenant = make.tenant()
    invite(db, tenant.id, " New.Admin@Example.com ", Role.ADMIN)
    res = client.get(
        "/v1/me", headers={"Authorization": "Bearer dev:fb_admin:new.admin@example.com"}
    )
    assert res.status_code == 200
    assert res.json()["role"] == "admin" and res.json()["tenant_id"] == tenant.id

    invite(db, tenant.id, "new.admin@example.com", Role.REVIEWER)  # changes the role
    res = client.get(
        "/v1/me", headers={"Authorization": "Bearer dev:fb_admin:new.admin@example.com"}
    )
    assert res.json()["role"] == "reviewer"


def test_remove_user_takes_away_access_but_keeps_audit_trail(
    client: TestClient, make: Factory, db: Session
) -> None:
    from app.cli import remove_user

    person = make.person(Role.ADMIN, name="Placeholder")
    case = make.case(person.tenant, person)
    assert (
        client.post(
            "/v1/devices", headers=person.headers, json={"token": "fcm-token-abcdef"}
        ).status_code
        == 201
    )
    client.patch(f"/v1/cases/{case.id}", headers=person.headers, json={"title": "Renamed"})
    email = person.user.email

    remove_user(db, email)
    db.refresh(person.user)
    assert person.user.active is False and person.user.firebase_uid is None
    assert person.user.email.endswith("@pruflo.invalid")
    assert (
        client.get("/v1/me", headers={"Authorization": f"Bearer dev:x:{email}"}).status_code == 403
    )
    # The audit trail still names them.
    admin = make.person(Role.ADMIN, person.tenant)
    items = client.get(f"/v1/cases/{case.id}/timeline", headers=admin.headers).json()["items"]
    assert items[0]["actor"]["name"] == "Placeholder"
