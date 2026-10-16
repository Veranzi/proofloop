"""Claims, findings and review decisions: endpoints 13-15."""

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import AuditEvent, OutboxEvent, ReviewAction
from app.enums import CaseStatus, ReviewDecision, Role
from tests.factories import Factory, key_headers


def _setup(make: Factory, status: CaseStatus = CaseStatus.IN_REVIEW):  # type: ignore[no-untyped-def]
    reviewer = make.person(Role.REVIEWER, name="Rita Reviewer")
    investigator = make.person(Role.INVESTIGATOR, reviewer.tenant)
    case = make.case(reviewer.tenant, reviewer, investigator)
    case.status = status
    make.db.commit()
    return reviewer, investigator, case


def test_findings_list_with_cited_evidence(client: TestClient, make: Factory) -> None:
    reviewer, _, case = _setup(make)
    finding = make.finding(case)
    items = client.get(f"/v1/cases/{case.id}/findings", headers=reviewer.headers).json()["items"]
    assert len(items) == 1
    f = items[0]
    assert f["id"] == finding.id and f["type"] == "quantity_shortfall"
    assert f["difference"] == {"value": "20", "unit": "units"}
    assert f["review"] == {
        "status": "pending",
        "by": None,
        "at": None,
        "note": "",
        "correction": None,
    }
    assert [(e["field"], e["value"], e["file_name"], e["quote"]) for e in f["evidence"]] == [
        ("ordered_quantity", "100", "purchase_order.pdf", "Qty ordered: 100"),
        ("delivered_quantity", "80", "delivery_note.pdf", "Received: 80"),
    ]
    claims = client.get(f"/v1/cases/{case.id}/claims", headers=reviewer.headers).json()["items"]
    assert {c["field"] for c in claims} == {"ordered_quantity", "delivered_quantity"}


def test_no_findings_is_an_empty_list(client: TestClient, make: Factory) -> None:
    reviewer, _, case = _setup(make)
    res = client.get(f"/v1/cases/{case.id}/findings", headers=reviewer.headers)
    assert res.json() == {"items": [], "next_cursor": None}


def test_decision_records_and_completes_the_case(
    client: TestClient, make: Factory, db: Session
) -> None:
    reviewer, _, case = _setup(make)
    first, second = make.finding(case), make.finding(case)
    url = f"/v1/cases/{case.id}/findings/{{}}/decision"

    res = client.post(
        url.format(first.id),
        headers=reviewer.headers,
        json={"decision": "approve", "note": "Supplier confirmed back-order."},
    )
    assert res.status_code == 200, res.text
    review = res.json()["review"]
    assert review["status"] == "approve" and review["by"]["name"] == "Rita Reviewer"
    db.refresh(case)
    assert case.status == CaseStatus.IN_REVIEW  # one finding still pending

    res = client.post(
        url.format(second.id),
        headers=reviewer.headers,
        json={
            "decision": "reject",
            "note": "Wrong delivery note.",
            "correction": {"field": "delivered_quantity", "previous": "80", "new": "100"},
        },
    )
    assert res.json()["review"]["correction"]["new"] == "100"
    db.refresh(case)
    assert case.status == CaseStatus.COMPLETED

    # Back to pending reopens the case.
    client.post(
        url.format(first.id),
        headers=reviewer.headers,
        json={"decision": "pending", "note": "Waiting for the supplier."},
    )
    db.refresh(case)
    assert case.status == CaseStatus.IN_REVIEW

    actions = db.scalars(select(ReviewAction).where(ReviewAction.case_id == case.id)).all()
    assert [a.decision for a in actions].count(ReviewDecision.APPROVE) == 1 and len(actions) == 3
    events = {
        e.type
        for e in db.scalars(select(OutboxEvent).where(OutboxEvent.tenant_id == case.tenant_id))
    }
    assert {"finding.decided", "case.completed", "case.in_review"} <= events
    activity = client.get("/v1/me/activity", headers=reviewer.headers).json()["items"]
    # One transaction in tests, so the three share a timestamp: check presence, not order.
    assert {a["kind"] for a in activity} == {"review_completed"}
    assert f"Set to pending a finding in {case.reference}" in {a["title"] for a in activity}


def test_reject_and_pending_need_a_note(client: TestClient, make: Factory) -> None:
    reviewer, _, case = _setup(make)
    finding = make.finding(case)
    url = f"/v1/cases/{case.id}/findings/{finding.id}/decision"
    for decision in ("reject", "pending"):
        res = client.post(url, headers=reviewer.headers, json={"decision": decision, "note": " "})
        assert res.status_code == 400
        assert "note" in res.json()["error"]["message"]
    assert client.post(url, headers=reviewer.headers, json={"decision": "maybe"}).status_code == 400


def test_who_may_decide(client: TestClient, make: Factory, db: Session) -> None:
    reviewer, investigator, case = _setup(make)
    finding = make.finding(case)
    url = f"/v1/cases/{case.id}/findings/{finding.id}/decision"
    body = {"decision": "approve"}
    assert client.post(url, headers=investigator.headers, json=body).status_code == 403
    viewer = make.person(Role.VIEWER, reviewer.tenant)
    assert client.post(url, headers=viewer.headers, json=body).status_code == 403
    _, key = make.api_key(reviewer.tenant, "cases:read", "cases:write", "findings:read")
    assert client.post(url, headers=key_headers(key), json=body).status_code == 403
    outsider = make.person(Role.REVIEWER, reviewer.tenant)  # not a member of the case
    assert client.post(url, headers=outsider.headers, json=body).status_code == 404
    admin = make.person(Role.ADMIN, reviewer.tenant)
    assert client.post(url, headers=admin.headers, json=body).status_code == 200
    assert db.scalar(select(AuditEvent).where(AuditEvent.action == "finding.decided"))


def test_findings_of_other_cases_are_hidden(client: TestClient, make: Factory) -> None:
    reviewer, _, case = _setup(make)
    other_case = make.case(reviewer.tenant, reviewer)
    finding = make.finding(other_case)
    url = f"/v1/cases/{case.id}/findings/{finding.id}/decision"
    assert (
        client.post(url, headers=reviewer.headers, json={"decision": "approve"}).status_code == 404
    )
