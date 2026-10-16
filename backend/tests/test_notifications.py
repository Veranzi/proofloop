"""Notifications (51-53), preferences, push, profile photo (54-56) and customer picker (57)."""

import io
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlsplit

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db.models import Device, Notification, OutboxEvent
from app.enums import CaseStatus, NotificationKind, Role
from app.services import cases as case_service
from app.services import notifications, push
from tests.factories import Factory, Person, key_headers
from tests.test_evidence import upload


def _bell(client: TestClient, person: Person) -> dict[str, Any]:
    res = client.get("/v1/me/notifications", headers=person.headers)
    assert res.status_code == 200
    return res.json()  # type: ignore[no-any-return]


def _count(db: Session, **where: Any) -> int:
    query = select(func.count()).select_from(Notification)
    for key, value in where.items():
        query = query.where(getattr(Notification, key) == value)
    return int(db.scalar(query) or 0)


# Who gets notified ----------------------------------------------------------------


def test_assignment_notifies_the_assignee_not_the_assigner(
    client: TestClient, make: Factory
) -> None:
    alice = make.person(Role.INVESTIGATOR, name="Alice")
    bob = make.person(Role.REVIEWER, alice.tenant, name="Bob")
    res = client.post(
        "/v1/cases",
        headers=alice.headers,
        json={"title": "Supplier audit", "assigned_to": bob.user.id},
    )
    case = res.json()
    bell = _bell(client, bob)
    assert bell["unread_count"] == 1
    note = bell["items"][0]
    assert note["kind"] == "case_assigned"
    assert note["title"] == f"{case['reference']} was assigned to you"
    assert note["link"] == f"/cases/{case['id']}" and note["case_reference"] == case["reference"]
    assert _bell(client, alice)["unread_count"] == 0

    # Assigning yourself doesn't notify you.
    client.patch(
        f"/v1/cases/{case['id']}", headers=alice.headers, json={"assigned_to": alice.user.id}
    )
    assert _bell(client, alice)["unread_count"] == 0


def test_preferences_switch_notifications_off(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    bob = make.person(Role.REVIEWER, alice.tenant)
    me = client.get("/v1/me", headers=bob.headers).json()
    assert me["notification_preferences"] == {
        "evidence_processed": True,
        "case_assigned": True,
        "case_in_review": True,
        "report_ready": True,
        "weekly_summary": False,
        "push": True,
    }
    res = client.patch(
        "/v1/me", headers=bob.headers, json={"notification_preferences": {"case_assigned": False}}
    )
    assert res.json()["notification_preferences"]["case_assigned"] is False
    assert res.json()["notification_preferences"]["report_ready"] is True  # others kept

    client.post("/v1/cases", headers=alice.headers, json={"title": "x", "assigned_to": bob.user.id})
    assert _bell(client, bob)["unread_count"] == 0

    bad = client.patch(
        "/v1/me", headers=bob.headers, json={"notification_preferences": {"sms": True}}
    )
    assert bad.status_code == 400


def test_processed_evidence_notifies_the_uploader(client: TestClient, make: Factory) -> None:
    from tests import samples

    alice = make.person(Role.INVESTIGATOR)
    case = make.case(alice.tenant, alice)
    data = samples.text_pdf([["Purchase Order PO-1001", "Qty ordered: 100"]])
    upload(client, alice, case.id, name="po.pdf", data=data)
    titles = [n["title"] for n in _bell(client, alice)["items"]]
    assert titles == ["po.pdf is processed"]

    upload(client, alice, case.id, name="scan.png", data=samples.PNG, content_type="image/png")
    # One test transaction, so both share a timestamp: find it by title, not position.
    notes = {n["title"]: n for n in _bell(client, alice)["items"]}
    assert "ocr not configured" in notes["scan.png needs a manual check"]["body"]


def test_case_ready_for_review_notifies_reviewers_on_the_case(
    client: TestClient, make: Factory, db: Session
) -> None:
    reviewer = make.person(Role.REVIEWER)
    investigator = make.person(Role.INVESTIGATOR, reviewer.tenant)
    outsider = make.person(Role.REVIEWER, reviewer.tenant)  # not a member
    case = make.case(reviewer.tenant, reviewer, investigator)
    make.finding(case)
    case_service.transition(db, case, CaseStatus.IN_REVIEW, reason="reconciled", pending_findings=1)
    db.commit()
    note = _bell(client, reviewer)["items"][0]
    assert note["kind"] == "case_in_review" and note["link"] == f"/review?case={case.id}"
    assert _bell(client, investigator)["unread_count"] == 0  # can't decide
    assert _bell(client, outsider)["unread_count"] == 0


def test_report_ready_notifies_the_requester(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    case = make.case(alice.tenant, alice)
    client.post(f"/v1/cases/{case.id}/reports", headers=alice.headers, json={"type": "summary"})
    note = _bell(client, alice)["items"][0]
    assert note["kind"] == "report_ready"
    assert note["title"] == f"{case.reference} Summary report is ready"
    assert note["link"] == f"/reports?case={case.id}"


# The bell ---------------------------------------------------------------------------


def test_mark_read_and_read_all(client: TestClient, make: Factory, db: Session) -> None:
    bob = make.person(Role.REVIEWER)
    for i in range(3):
        notifications.notify(
            db, bob.tenant.id, [bob.user.id], NotificationKind.CASE_ASSIGNED, f"Case {i}"
        )
    db.commit()
    bell = _bell(client, bob)
    assert bell["unread_count"] == 3
    first = bell["items"][0]["id"]
    res = client.post(f"/v1/me/notifications/{first}/read", headers=bob.headers)
    assert res.json()["read"] is True
    assert _bell(client, bob)["unread_count"] == 2
    unread = client.get("/v1/me/notifications?unread_only=true", headers=bob.headers).json()
    assert first not in {n["id"] for n in unread["items"]}
    assert client.post("/v1/me/notifications/read-all", headers=bob.headers).json() == {
        "updated": 2
    }
    assert _bell(client, bob)["unread_count"] == 0

    other = make.person(Role.REVIEWER, bob.tenant)
    assert (
        client.post(f"/v1/me/notifications/{first}/read", headers=other.headers).status_code == 404
    )
    _, key = make.api_key(bob.tenant, "cases:read")
    assert client.get("/v1/me/notifications", headers=key_headers(key)).status_code == 403


def test_weekly_summary_once_a_week_for_those_who_want_it(
    client: TestClient, make: Factory, db: Session
) -> None:
    keen = make.person(Role.INVESTIGATOR)
    quiet = make.person(Role.INVESTIGATOR, keen.tenant)
    make.case(keen.tenant, keen).status = CaseStatus.IN_REVIEW
    db.commit()
    client.patch(
        "/v1/me", headers=keen.headers, json={"notification_preferences": {"weekly_summary": True}}
    )
    monday = datetime(2026, 10, 19, 7, tzinfo=UTC)
    notifications.weekly_summary(db, monday)
    notifications.weekly_summary(db, monday + timedelta(hours=3))  # same week: no repeat
    assert _count(db, user_id=keen.user.id, kind="weekly_summary") == 1
    assert _count(db, user_id=quiet.user.id, kind="weekly_summary") == 0
    body = _bell(client, keen)["items"][0]["body"]
    assert body.startswith("1 in review, 0 awaiting evidence, 0 completed.")


def test_old_notifications_are_purged(make: Factory, db: Session) -> None:
    bob = make.person(Role.REVIEWER)
    notifications.notify(db, bob.tenant.id, [bob.user.id], NotificationKind.CASE_ASSIGNED, "Old")
    db.commit()
    assert notifications.purge_old(db, datetime.now(UTC) + timedelta(days=91)) >= 1
    assert _count(db, user_id=bob.user.id) == 0


# Push ---------------------------------------------------------------------------------


def test_push_goes_to_devices_and_dead_tokens_are_removed(
    client: TestClient, make: Factory, db: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    sent: list[tuple[list[str], str, str]] = []

    def fake_fcm(tokens: list[str], title: str, body: str, link: str) -> list[str]:
        sent.append((tokens, title, link))
        return ["dead-token-123456"]

    monkeypatch.setattr(push, "fcm_send", fake_fcm)
    alice = make.person(Role.INVESTIGATOR)
    bob = make.person(Role.REVIEWER, alice.tenant)
    for token in ("live-token-123456", "dead-token-123456"):
        client.post("/v1/devices", headers=bob.headers, json={"token": token})

    case = client.post(
        "/v1/cases", headers=alice.headers, json={"title": "x", "assigned_to": bob.user.id}
    ).json()
    assert db.scalar(select(OutboxEvent).where(OutboxEvent.type == "push.send"))
    queued = db.scalar(select(OutboxEvent).where(OutboxEvent.type == "push.send"))
    assert queued is not None
    assert push.send_push(db, queued.payload["notification_ids"]) == 1
    tokens, title, link = sent[0]
    assert sorted(tokens) == ["dead-token-123456", "live-token-123456"]
    assert title == f"{case['reference']} was assigned to you"
    assert link == f"https://pruflo.web.app/#/cases/{case['id']}"
    remaining = db.scalars(select(Device.token).where(Device.user_id == bob.user.id)).all()
    assert remaining == ["live-token-123456"]


def test_no_push_when_switched_off(client: TestClient, make: Factory, db: Session) -> None:
    alice = make.person(Role.INVESTIGATOR)
    bob = make.person(Role.REVIEWER, alice.tenant)
    client.patch("/v1/me", headers=bob.headers, json={"notification_preferences": {"push": False}})
    client.post("/v1/cases", headers=alice.headers, json={"title": "x", "assigned_to": bob.user.id})
    assert _bell(client, bob)["unread_count"] == 1  # still in the app
    assert db.scalar(select(OutboxEvent).where(OutboxEvent.type == "push.send")) is None


# Profile photo --------------------------------------------------------------------------


def _jpeg_with_gps(size: tuple[int, int] = (1200, 900)) -> bytes:
    image = Image.new("RGB", size, (200, 30, 30))
    exif = Image.Exif()
    exif[0x8825] = {1: "N", 2: (1.0, 17.0, 0.0)}  # GPS location (near Singapore)
    exif[0x010F] = "PhoneMaker"
    out = io.BytesIO()
    image.save(out, format="JPEG", exif=exif)
    return out.getvalue()


def _put_photo(client: TestClient, person: Person, data: bytes, content_type: str) -> Any:
    slot = client.post(
        "/v1/me/avatar/upload-url",
        headers=person.headers,
        json={"content_type": content_type, "size_bytes": len(data)},
    )
    assert slot.status_code == 201, slot.text
    parts = urlsplit(slot.json()["upload_url"])
    put = client.put(f"{parts.path}?{parts.query}", content=data, headers=slot.json()["headers"])
    assert put.status_code == 200
    return client.post("/v1/me/avatar/complete", headers=person.headers)


def test_photo_is_resized_and_stripped_of_metadata(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    original = _jpeg_with_gps()
    assert Image.open(io.BytesIO(original)).getexif()  # the test photo does carry EXIF
    res = _put_photo(client, alice, original, "image/jpeg")
    assert res.status_code == 200, res.text
    url = res.json()["avatar_url"]
    parts = urlsplit(url)
    stored = client.get(f"{parts.path}?{parts.query}").content
    photo = Image.open(io.BytesIO(stored))
    assert photo.format == "JPEG" and max(photo.size) == 512
    assert not photo.getexif()  # no GPS, no camera details

    assert client.get("/v1/me", headers=alice.headers).json()["avatar_url"]
    assert client.delete("/v1/me/avatar", headers=alice.headers).status_code == 204
    assert client.get("/v1/me", headers=alice.headers).json()["avatar_url"] is None


def test_photo_validation(client: TestClient, make: Factory) -> None:
    alice = make.person(Role.INVESTIGATOR)
    too_big = client.post(
        "/v1/me/avatar/upload-url",
        headers=alice.headers,
        json={"content_type": "image/png", "size_bytes": 6 * 1024 * 1024},
    )
    assert too_big.status_code == 400
    gif = client.post(
        "/v1/me/avatar/upload-url",
        headers=alice.headers,
        json={"content_type": "image/gif", "size_bytes": 10},
    )
    assert gif.status_code == 400
    assert client.post("/v1/me/avatar/complete", headers=alice.headers).status_code == 409
    fake = _put_photo(client, alice, b"<svg>not a photo</svg>", "image/png")
    assert fake.status_code == 400 and fake.json()["error"]["code"] == "unsupported_file"


# Customer picker -------------------------------------------------------------------------


def test_customer_picker_and_names_on_cases(client: TestClient, make: Factory) -> None:
    admin = make.person(Role.ADMIN)
    investigator = make.person(Role.INVESTIGATOR, admin.tenant)
    customer = client.post(
        "/v1/admin/customers", headers=admin.headers, json={"name": "Acme Supplies"}
    ).json()
    picker = client.get("/v1/customers", headers=investigator.headers).json()["items"]
    assert picker == [{"id": customer["id"], "name": "Acme Supplies"}]
    _, key = make.api_key(admin.tenant, "cases:read")
    assert client.get("/v1/customers", headers=key_headers(key)).status_code == 200
    other = make.person(Role.INVESTIGATOR)
    assert client.get("/v1/customers", headers=other.headers).json()["items"] == []

    case = client.post(
        "/v1/cases",
        headers=investigator.headers,
        json={"title": "Audit", "customer_id": customer["id"]},
    ).json()
    assert case["customer_name"] == "Acme Supplies"
    listed = client.get("/v1/cases", headers=investigator.headers).json()["items"][0]
    assert listed["customer_name"] == "Acme Supplies"
