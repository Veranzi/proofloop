"""Rules (46-47) and providers (48-49)."""

from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db.models import RuleVersion
from app.enums import Role
from tests.factories import Factory, key_headers


def test_rules_are_created_with_defaults(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    items = client.get("/v1/admin/rules", headers=admin.headers).json()["items"]
    assert [r["template"] for r in items] == [
        "quantity_shortfall",
        "amount_mismatch",
        "delivery_date_window",
        "missing_document",
    ]
    qty = items[0]
    assert qty["version"] == 1 and qty["enabled"] is True
    assert qty["params"] == [
        {"key": "tolerance_units", "label": "Allowed difference", "value": "0", "suffix": "units"}
    ]
    again = client.get("/v1/admin/rules", headers=admin.headers).json()["items"]
    assert [r["id"] for r in again] == [r["id"] for r in items]  # created once


def test_parameter_change_adds_a_version_toggle_does_not(
    client: TestClient, make: Factory, db: Session
) -> None:
    admin = make.person(Role.ADMIN)
    rule = client.get("/v1/admin/rules", headers=admin.headers).json()["items"][0]
    url = f"/v1/admin/rules/{rule['id']}"

    res = client.patch(url, headers=admin.headers, json={"enabled": False})
    assert res.json()["enabled"] is False and res.json()["version"] == 1
    res = client.patch(url, headers=admin.headers, json={"params": {"tolerance_units": "2.50"}})
    assert res.json()["version"] == 2 and res.json()["params"][0]["value"] == "2.5"
    res = client.patch(url, headers=admin.headers, json={"params": {"tolerance_units": "2.5"}})
    assert res.json()["version"] == 2  # same value: no new version

    versions = db.scalar(
        select(func.count()).select_from(RuleVersion).where(RuleVersion.rule_id == rule["id"])
    )
    assert versions == 2  # the old version is kept


def test_rule_validation(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    items = client.get("/v1/admin/rules", headers=admin.headers).json()["items"]
    qty, amount = items[0]["id"], items[1]["id"]
    for rule_id, params in (
        (qty, {"tolerance_units": "-1"}),
        (qty, {"tolerance_units": "lots"}),
        (qty, {"formula": "1+1"}),
        (amount, {"tolerance_percent": "101"}),
    ):
        res = client.patch(
            f"/v1/admin/rules/{rule_id}", headers=admin.headers, json={"params": params}
        )
        assert res.status_code == 400, params
    other = make.person(Role.ADMIN)
    assert (
        client.patch(
            f"/v1/admin/rules/{qty}", headers=other.headers, json={"enabled": False}
        ).status_code
        == 404
    )


def test_providers_defaults_and_validation(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    assert client.get("/v1/admin/providers", headers=admin.headers).json() == {
        "ocr": "google_document_ai",
        "ai": "vertex_gemini",
        "model": "gemini-2.5-flash",
        "region": "asia-southeast1",
    }
    ok = {
        "ocr": "google_document_ai",
        "ai": "vertex_gemini",
        "model": "gemini-2.5-pro",
        "region": "asia-southeast2",
    }
    assert client.put("/v1/admin/providers", headers=admin.headers, json=ok).json() == ok

    for change, code in (
        ({"ocr": "aws_textract"}, "provider_not_available"),
        ({"ai": "azure_openai"}, "provider_not_available"),
        ({"model": "gpt-4o"}, "validation_failed"),
        ({"region": "africa-south1"}, "validation_failed"),
    ):
        res = client.put("/v1/admin/providers", headers=admin.headers, json={**ok, **change})
        assert res.status_code == 400 and res.json()["error"]["code"] == code, change


def test_rules_and_providers_are_admin_only(client: TestClient, make: Factory) -> None:
    reviewer = make.person(Role.REVIEWER)
    _, key = make.api_key(reviewer.tenant, "cases:read")
    for path in ("/v1/admin/rules", "/v1/admin/providers"):
        assert client.get(path, headers=reviewer.headers).status_code == 403
        assert client.get(path, headers=key_headers(key)).status_code == 403
