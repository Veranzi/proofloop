"""Document sources (43-45): honestly unavailable until importers exist."""

from fastapi.testclient import TestClient

from app.enums import Role
from tests.factories import Factory


def test_sources_are_listed_as_coming_soon(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    items = client.get("/v1/admin/connectors", headers=admin.headers).json()["items"]
    assert [i["kind"] for i in items] == [
        "email_inbox",
        "google_drive",
        "sharepoint",
        "odoo",
        "sap",
    ]
    assert {i["status"] for i in items} == {"coming_soon"}


def test_connecting_is_refused_and_disconnect_is_harmless(
    client: TestClient, make: Factory
) -> None:
    admin = make.person(Role.ADMIN)
    res = client.put(
        "/v1/admin/connectors/odoo",
        headers=admin.headers,
        json={"url": "https://x.odoo.com", "database": "x", "username": "u", "api_key": "k"},
    )
    assert res.status_code == 400 and res.json()["error"]["code"] == "connector_not_available"
    assert client.delete("/v1/admin/connectors/odoo", headers=admin.headers).status_code == 204
    assert client.put("/v1/admin/connectors/fax", headers=admin.headers, json={}).status_code == 400


def test_sources_are_admin_only(client: TestClient, make: Factory) -> None:
    reviewer = make.person(Role.REVIEWER)
    assert client.get("/v1/admin/connectors", headers=reviewer.headers).status_code == 403
