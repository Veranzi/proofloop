from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import CaseMember, OutboxEvent
from app.enums import CaseStatus, Role
from app.services import cases as case_service
from tests.factories import Factory, key_headers


def _create(client: TestClient, headers: dict[str, str], **body: object) -> dict:  # type: ignore[type-arg]
    res = client.post("/v1/cases", headers=headers, json={"title": "Fraud Investigation", **body})
    assert res.status_code == 201, res.text
    return res.json()  # type: ignore[no-any-return]


def test_create_case_defaults_reference_and_membership(
    client: TestClient, make: Factory, db: Session
) -> None:
    alice = make.person(Role.INVESTIGATOR, name="Alice")
    bob = make.person(Role.REVIEWER, tenant=alice.tenant, name="Bob")
    first = _create(
        client, alice.headers, category="Procurement", priority="high", assigned_to=bob.user.id
    )
    second = _create(client, alice.headers)

    assert first["reference"] == "PL-001" and second["reference"] == "PL-002"
    assert first["status"] == "awaiting_evidence"
    assert first["priority"] == "high"
    assert first["assigned_to"] == {"uid": bob.user.id, "name": "Bob"}
    members = set(db.scalars(select(CaseMember.user_id).where(CaseMember.case_id == first["id"])))
    assert members == {alice.user.id, bob.user.id}


def test_references_are_per_tenant(client: TestClient, make: Factory) -> None:
    a = make.person(Role.INVESTIGATOR)
    b = make.person(Role.INVESTIGATOR)  # a different tenant
    assert _create(client, a.headers)["reference"] == "PL-001"
    assert _create(client, b.headers)["reference"] == "PL-001"


def test_who_can_create(client: TestClient, make: Factory) -> None:
    tenant = make.tenant()
    for role, expected in (
        (Role.INVESTIGATOR, 201),
        (Role.ADMIN, 201),
        (Role.REVIEWER, 403),
        (Role.VIEWER, 403),
    ):
        person = make.person(role, tenant)
        res = client.post("/v1/cases", headers=person.headers, json={"title": "x"})
        assert res.status_code == expected, role

    _, write_key = make.api_key(tenant, "cases:write")
    _, read_key = make.api_key(tenant, "cases:read")
    assert (
        client.post("/v1/cases", headers=key_headers(write_key), json={"title": "x"}).status_code
        == 201
    )
    assert (
        client.post("/v1/cases", headers=key_headers(read_key), json={"title": "x"}).status_code
        == 403
    )


def test_create_validation(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    outsider = make.person(Role.INVESTIGATOR)  # another tenant
    for body, field in (
        ({"title": ""}, "title"),
        ({"title": "x", "priority": "urgent"}, "priority"),
        ({"title": "x", "assigned_to": outsider.user.id}, "assigned_to"),
        ({"title": "x", "customer_id": "cus_nope"}, "customer_id"),
    ):
        res = client.post("/v1/cases", headers=alice.headers, json=body)
        assert res.status_code == 400, body
        assert res.json()["error"]["field"] == field


def test_members_admins_and_keys_see_cases_others_get_404(
    client: TestClient, make: Factory
) -> None:
    alice = make.person(Role.INVESTIGATOR)
    tenant = alice.tenant
    case = _create(client, alice.headers)
    colleague = make.person(Role.REVIEWER, tenant)  # same tenant, not a member
    admin = make.person(Role.ADMIN, tenant)
    stranger = make.person(Role.ADMIN)  # admin of another tenant
    _, key = make.api_key(tenant, "cases:read")

    assert client.get(f"/v1/cases/{case['id']}", headers=alice.headers).status_code == 200
    assert client.get(f"/v1/cases/{case['id']}", headers=admin.headers).status_code == 200
    assert client.get(f"/v1/cases/{case['id']}", headers=key_headers(key)).status_code == 200
    for outsider in (colleague, stranger):
        res = client.get(f"/v1/cases/{case['id']}", headers=outsider.headers)
        assert res.status_code == 404
        assert (
            client.get(f"/v1/cases/{case['id']}/timeline", headers=outsider.headers).status_code
            == 404
        )

    assert client.get("/v1/cases", headers=colleague.headers).json()["items"] == []
    assert [c["id"] for c in client.get("/v1/cases", headers=admin.headers).json()["items"]] == [
        case["id"]
    ]
    assert client.get("/v1/cases", headers=stranger.headers).json()["items"] == []


def test_list_filters_and_paging(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    for title in ("Invoice gap", "Delivery short", "Invoice overcharge"):
        _create(
            client, alice.headers, title=title, priority="low" if "Delivery" in title else "high"
        )

    page1 = client.get("/v1/cases?limit=2", headers=alice.headers).json()
    page2 = client.get(
        f"/v1/cases?limit=2&cursor={page1['next_cursor']}", headers=alice.headers
    ).json()
    assert len(page1["items"]) == 2 and len(page2["items"]) == 1 and page2["next_cursor"] is None

    found = client.get("/v1/cases?q=invoice", headers=alice.headers).json()["items"]
    assert {c["title"] for c in found} == {"Invoice gap", "Invoice overcharge"}
    assert len(client.get("/v1/cases?priority=low", headers=alice.headers).json()["items"]) == 1
    assert len(client.get("/v1/cases?status=in_review", headers=alice.headers).json()["items"]) == 0
    assert client.get("/v1/cases?status=reviewed", headers=alice.headers).status_code == 400


def test_patch_case_and_version_check(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    case = _create(client, alice.headers)
    url = f"/v1/cases/{case['id']}"

    res = client.patch(
        url, headers=alice.headers, json={"priority": "high", "version": case["version"]}
    )
    assert res.status_code == 200
    assert res.json()["priority"] == "high" and res.json()["version"] == case["version"] + 1

    stale = client.patch(
        url, headers=alice.headers, json={"title": "New", "version": case["version"]}
    )
    assert stale.status_code == 409

    # Status can't be set by hand; unknown fields are ignored.
    res = client.patch(url, headers=alice.headers, json={"status": "completed"})
    assert res.json()["status"] == "awaiting_evidence"

    reviewer = make.person(Role.REVIEWER, alice.tenant)
    assert client.patch(url, headers=reviewer.headers, json={"title": "x"}).status_code == 403


def test_timeline_shows_actions_with_actor(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR, name="Alice")
    case = _create(client, alice.headers)
    client.patch(f"/v1/cases/{case['id']}", headers=alice.headers, json={"title": "Renamed"})

    items = client.get(f"/v1/cases/{case['id']}/timeline", headers=alice.headers).json()["items"]
    assert {i["action"] for i in items} == {"case.created", "case.updated"}
    assert all(i["actor"] == {"uid": alice.user.id, "name": "Alice"} for i in items)
    assert all(i["actor_type"] == "person" for i in items)


def test_status_transition_audits_and_emits_webhook(make: Factory, db: Session) -> None:
    alice = make.person(Role.INVESTIGATOR)
    case = make.case(alice.tenant, alice)

    assert case_service.transition(
        db, case, CaseStatus.IN_REVIEW, reason="processed", pending_findings=3
    )
    assert not case_service.transition(db, case, CaseStatus.IN_REVIEW, reason="again")
    assert case_service.transition(db, case, CaseStatus.COMPLETED, reason="all decided")
    db.commit()

    events = db.scalars(
        select(OutboxEvent).where(OutboxEvent.tenant_id == alice.tenant.id).order_by(OutboxEvent.id)
    ).all()
    by_type = {e.type: e.payload for e in events}
    assert by_type["case.in_review"] == {"case_id": case.id, "pending_findings": 3}
    assert by_type["case.completed"] == {"case_id": case.id}
    assert case.status == CaseStatus.COMPLETED
