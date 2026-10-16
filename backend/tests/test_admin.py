"""Admin endpoints 24-33."""

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.enums import Role
from tests.factories import Factory, key_headers


def test_only_admins_reach_admin_routes(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    for role in (Role.INVESTIGATOR, Role.REVIEWER, Role.VIEWER):
        person = make.person(role, admin.tenant)
        assert client.get("/v1/admin/users", headers=person.headers).status_code == 403
    _, key = make.api_key(admin.tenant, "cases:read", "cases:write", "findings:read")
    assert client.get("/v1/admin/users", headers=key_headers(key)).status_code == 403
    assert client.get("/v1/admin/users", headers=admin.headers).status_code == 200


def test_invite_list_and_sign_in(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN, name="Ada")
    res = client.post(
        "/v1/admin/users",
        headers=admin.headers,
        json={"email": " Sam@Example.com ", "name": "Sam", "role": "reviewer"},
    )
    assert res.status_code == 201, res.text
    sam = res.json()
    assert sam["email"] == "sam@example.com" and sam["role"] == "reviewer"
    assert sam["signed_in"] is False

    me = client.get("/v1/me", headers={"Authorization": "Bearer dev:fb_sam:sam@example.com"})
    assert me.status_code == 200 and me.json()["role"] == "reviewer"

    listed = client.get("/v1/admin/users", headers=admin.headers).json()["items"]
    assert {u["email"]: u["signed_in"] for u in listed}["sam@example.com"] is True
    found = client.get("/v1/admin/users?q=sam", headers=admin.headers).json()["items"]
    assert [u["email"] for u in found] == ["sam@example.com"]

    bad = client.post(
        "/v1/admin/users", headers=admin.headers, json={"email": "not-an-email", "role": "reviewer"}
    )
    assert bad.status_code == 400


def test_change_role_disable_and_last_admin_rule(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    url = f"/v1/admin/users/{admin.user.id}"
    for body in ({"role": "reviewer"}, {"active": False}):
        res = client.patch(url, headers=admin.headers, json=body)
        assert res.status_code == 409, body
        assert "at least one active admin" in res.json()["error"]["message"]
    assert client.delete(url, headers=admin.headers).status_code == 409

    other = make.person(Role.INVESTIGATOR, admin.tenant)
    res = client.patch(
        f"/v1/admin/users/{other.user.id}", headers=admin.headers, json={"role": "admin"}
    )
    assert res.json()["role"] == "admin"
    res = client.patch(
        f"/v1/admin/users/{other.user.id}", headers=admin.headers, json={"active": False}
    )
    assert res.json()["active"] is False
    assert client.get("/v1/me", headers=other.headers).status_code == 403  # disabled


def test_remove_user_from_organisation(client: TestClient, make: Factory, db: Session) -> None:
    admin = make.person(Role.ADMIN)
    person = make.person(Role.INVESTIGATOR, admin.tenant)
    case = make.case(admin.tenant, person)
    headers = person.headers
    assert (
        client.delete(f"/v1/admin/users/{person.user.id}", headers=admin.headers).status_code == 204
    )
    assert client.get("/v1/me", headers=headers).status_code == 403
    members = client.get(f"/v1/admin/cases/{case.id}/members", headers=admin.headers).json()
    assert members["items"] == []
    db.refresh(person.user)
    assert person.user.email.endswith("@pruflo.invalid")  # no other organisation: anonymised


def test_admins_cannot_touch_other_organisations(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    stranger = make.person(Role.INVESTIGATOR)
    other_case = make.case(stranger.tenant, stranger)
    url = f"/v1/admin/users/{stranger.user.id}"
    assert client.patch(url, headers=admin.headers, json={"role": "viewer"}).status_code == 404
    assert client.delete(url, headers=admin.headers).status_code == 404
    res = client.get(f"/v1/admin/cases/{other_case.id}/members", headers=admin.headers)
    assert res.status_code == 404


def test_customers(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    res = client.post(
        "/v1/admin/customers",
        headers=admin.headers,
        json={"name": "Acme Supplies", "contact_email": "Ops@Acme.com"},
    )
    assert res.status_code == 201
    customer = res.json()
    assert customer["contact_email"] == "ops@acme.com"
    res = client.patch(
        f"/v1/admin/customers/{customer['id']}",
        headers=admin.headers,
        json={"name": "Acme Supplies Ltd"},
    )
    assert res.json()["name"] == "Acme Supplies Ltd"
    listed = client.get("/v1/admin/customers", headers=admin.headers).json()["items"]
    assert [c["name"] for c in listed] == ["Acme Supplies Ltd"]

    # Customers can now be attached to cases.
    investigator = make.person(Role.INVESTIGATOR, admin.tenant)
    res = client.post(
        "/v1/cases",
        headers=investigator.headers,
        json={"title": "Supplier audit", "customer_id": customer["id"]},
    )
    assert res.status_code == 201

    other_admin = make.person(Role.ADMIN)
    res = client.patch(
        f"/v1/admin/customers/{customer['id']}", headers=other_admin.headers, json={"name": "x"}
    )
    assert res.status_code == 404


def test_case_members(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    alice = make.person(Role.INVESTIGATOR, admin.tenant, name="Alice")
    bob = make.person(Role.REVIEWER, admin.tenant, name="Bob")
    outsider = make.person(Role.REVIEWER)
    case = make.case(admin.tenant, alice)
    url = f"/v1/admin/cases/{case.id}/members"

    res = client.put(url, headers=admin.headers, json={"user_ids": [bob.user.id]})
    assert [m["name"] for m in res.json()["items"]] == ["Bob"]
    assert client.get(f"/v1/cases/{case.id}", headers=alice.headers).status_code == 404
    assert client.get(f"/v1/cases/{case.id}", headers=bob.headers).status_code == 200

    res = client.put(url, headers=admin.headers, json={"user_ids": [outsider.user.id]})
    assert res.status_code == 400


def test_audit_log(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN, name="Ada")
    client.post(
        "/v1/admin/users",
        headers=admin.headers,
        json={"email": "new@example.com", "role": "viewer"},
    )
    client.post("/v1/admin/customers", headers=admin.headers, json={"name": "Acme"})
    other = make.person(Role.ADMIN)
    client.post("/v1/admin/customers", headers=other.headers, json={"name": "Not mine"})

    items = client.get("/v1/admin/audit", headers=admin.headers).json()["items"]
    assert {i["action"] for i in items} == {"user.invited", "customer.created"}
    assert all(i["actor"] == {"uid": admin.user.id, "name": "Ada"} for i in items)
    only = client.get("/v1/admin/audit?action=user.invited", headers=admin.headers).json()
    assert [i["action"] for i in only["items"]] == ["user.invited"]
