"""Webhooks: endpoints 37-42, signing, delivery, retries and SSRF protection."""

import hashlib
import hmac
import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import WebhookDelivery, WebhookEndpoint
from app.enums import CaseStatus, Role
from app.services import net_guard, webhooks
from tests.factories import Factory, Person

PUBLIC_IP = "93.184.216.34"


class Receiver:
    """Stands in for the HTTP call; answers with the queued status codes."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.statuses: list[int] = []

    def __call__(self, url: str, headers: dict[str, str], body: bytes) -> int:
        self.calls.append({"url": url, "headers": headers, "body": body})
        return self.statuses.pop(0) if self.statuses else 200


@pytest.fixture
def receiver(monkeypatch: pytest.MonkeyPatch) -> Receiver:
    monkeypatch.setattr(net_guard, "resolve", lambda host: [PUBLIC_IP])
    fake = Receiver()
    monkeypatch.setattr(webhooks, "transport", fake)
    return fake


def _create(
    client: TestClient, admin: Person, events: list[str], url: str = "https://erp.example.com/hooks"
) -> Any:
    res = client.post(
        "/v1/admin/webhooks",
        headers=admin.headers,
        json={"url": url, "description": "ERP", "events": events},
    )
    assert res.status_code == 201, res.text
    return res.json()


def _decide(client: TestClient, make: Factory, admin: Person) -> str:
    case = make.case(admin.tenant, admin)
    case.status = CaseStatus.IN_REVIEW
    make.db.commit()
    finding = make.finding(case)
    res = client.post(
        f"/v1/cases/{case.id}/findings/{finding.id}/decision",
        headers=admin.headers,
        json={"decision": "approve"},
    )
    assert res.status_code == 200
    return finding.id


def test_create_shows_secret_once_and_stores_it_encrypted(
    client: TestClient, make: Factory, db: Session, receiver: Receiver
) -> None:
    admin = make.person(Role.ADMIN)
    created = _create(client, admin, ["finding.decided"])
    secret = created["signing_secret"]
    assert secret.startswith("whsec_") and len(secret) == 38
    stored = db.get(WebhookEndpoint, created["id"])
    assert stored is not None and secret not in stored.secret_ref
    listed = client.get("/v1/admin/webhooks", headers=admin.headers).json()["items"]
    assert "signing_secret" not in listed[0] and listed[0]["events"] == ["finding.decided"]


@pytest.mark.parametrize(
    ("url", "resolved"),
    [
        ("http://erp.example.com/hooks", [PUBLIC_IP]),  # not https
        ("https://user:pw@erp.example.com/hooks", [PUBLIC_IP]),
        ("https://localhost/hooks", ["127.0.0.1"]),
        ("https://10.0.0.5/hooks", []),
        ("https://169.254.169.254/computeMetadata", []),  # cloud metadata
        ("https://metadata.google.internal/x", [PUBLIC_IP]),
        ("https://rebind.example.com/hooks", ["192.168.1.10"]),  # DNS points inside
        ("https://[::1]/hooks", []),
    ],
)
def test_unsafe_urls_are_refused(
    client: TestClient,
    make: Factory,
    monkeypatch: pytest.MonkeyPatch,
    url: str,
    resolved: list[str],
) -> None:
    monkeypatch.setattr(net_guard, "resolve", lambda host: resolved)
    admin = make.person(Role.ADMIN)
    res = client.post(
        "/v1/admin/webhooks",
        headers=admin.headers,
        json={"url": url, "events": ["finding.decided"]},
    )
    assert res.status_code == 400, url
    assert res.json()["error"]["field"] == "url"


def test_events_are_signed_and_sent_to_subscribers(
    client: TestClient, make: Factory, db: Session, receiver: Receiver
) -> None:
    admin = make.person(Role.ADMIN)
    subscribed = _create(client, admin, ["finding.decided"])
    _create(client, admin, ["report.ready"], url="https://other.example.com/hooks")
    finding_id = _decide(client, make, admin)

    assert len(receiver.calls) == 1  # only the endpoint subscribed to finding.decided
    call = receiver.calls[0]
    body = json.loads(call["body"])
    assert body["type"] == "finding.decided" and body["id"].startswith("evt_")
    assert body["data"]["finding_id"] == finding_id and body["data"]["decision"] == "approve"
    assert call["headers"]["X-Pruflo-Event"] == "finding.decided"

    t, v1 = (part.split("=", 1)[1] for part in call["headers"]["X-Pruflo-Signature"].split(","))
    expected = hmac.new(
        subscribed["signing_secret"].encode(), f"{t}.".encode() + call["body"], hashlib.sha256
    ).hexdigest()
    assert hmac.compare_digest(v1, expected)

    listed = client.get("/v1/admin/webhooks", headers=admin.headers).json()["items"]
    recent = {w["id"]: w["recent_deliveries"] for w in listed}[subscribed["id"]]
    assert [(d["event"], d["status_code"], d["attempt"]) for d in recent] == [
        ("finding.decided", 200, 1)
    ]

    # Delivering the same event again doesn't send it twice.
    event_id = body["id"]
    assert webhooks.fanout(db, event_id) == 0


def test_failed_deliveries_retry_on_schedule_then_stop(
    client: TestClient, make: Factory, db: Session, receiver: Receiver
) -> None:
    admin = make.person(Role.ADMIN)
    hook = _create(client, admin, ["finding.decided"])
    receiver.statuses = [503] * 10
    _decide(client, make, admin)
    first = db.scalar(select(WebhookDelivery).where(WebhookDelivery.endpoint_id == hook["id"]))
    assert first is not None and first.status_code == 503 and first.next_attempt_at is not None

    now = datetime.now(UTC)
    assert webhooks.retry_due(db, now) == 0  # not due yet
    for minutes in (2, 7, 40, 3 * 60, 9 * 60, 22 * 60, 23 * 60):
        webhooks.retry_due(db, now + timedelta(minutes=minutes))
    attempts = db.scalars(
        select(WebhookDelivery.attempt)
        .where(WebhookDelivery.endpoint_id == hook["id"])
        .order_by(WebhookDelivery.attempt)
    ).all()
    # The first try plus the six retries in the contract (1m, 5m, 30m, 2h, 6h, 12h).
    assert attempts == [1, 2, 3, 4, 5, 6, 7]
    pending = db.scalars(
        select(WebhookDelivery).where(
            WebhookDelivery.endpoint_id == hook["id"], WebhookDelivery.next_attempt_at.is_not(None)
        )
    ).all()
    assert pending == []
    endpoint = db.get(WebhookEndpoint, hook["id"])
    assert endpoint is not None and endpoint.failing_since is not None


def test_success_clears_failure_and_long_failure_pauses(
    client: TestClient, make: Factory, db: Session, receiver: Receiver
) -> None:
    admin = make.person(Role.ADMIN)
    hook = _create(client, admin, ["finding.decided"])
    endpoint = db.get(WebhookEndpoint, hook["id"])
    assert endpoint is not None
    endpoint.failing_since = datetime.now(UTC) - timedelta(days=1)
    db.commit()
    _decide(client, make, admin)  # receiver answers 200
    db.refresh(endpoint)
    assert endpoint.failing_since is None

    endpoint.failing_since = datetime.now(UTC) - timedelta(days=4)
    db.commit()
    receiver.statuses = [500]
    _decide(client, make, admin)
    db.refresh(endpoint)
    assert endpoint.active is False  # paused

    res = client.patch(
        f"/v1/admin/webhooks/{hook['id']}", headers=admin.headers, json={"active": True}
    )
    assert res.json()["active"] is True
    db.refresh(endpoint)
    assert endpoint.failing_since is None


def test_ping_update_delete_and_log(client: TestClient, make: Factory, receiver: Receiver) -> None:
    admin = make.person(Role.ADMIN)
    hook = _create(client, admin, ["finding.decided"])
    url = f"/v1/admin/webhooks/{hook['id']}"

    receiver.statuses = [404]
    ping = client.post(f"{url}/test", headers=admin.headers).json()
    assert (ping["event"], ping["status_code"], ping["attempt"]) == ("ping", 404, 1)
    log = client.get(f"{url}/deliveries", headers=admin.headers).json()["items"]
    assert [d["event"] for d in log] == ["ping"]

    res = client.patch(
        url,
        headers=admin.headers,
        json={"events": ["report.ready", "case.completed"], "description": "New"},
    )
    assert res.json()["events"] == ["case.completed", "report.ready"]
    assert client.patch(url, headers=admin.headers, json={"events": ["ping"]}).status_code == 400
    assert client.delete(url, headers=admin.headers).status_code == 204
    assert client.get(f"{url}/deliveries", headers=admin.headers).status_code == 404


def test_webhooks_are_admin_only_and_per_organisation(
    client: TestClient, make: Factory, receiver: Receiver
) -> None:
    admin = make.person(Role.ADMIN)
    hook = _create(client, admin, ["finding.decided"])
    reviewer = make.person(Role.REVIEWER, admin.tenant)
    assert client.get("/v1/admin/webhooks", headers=reviewer.headers).status_code == 403
    other_admin = make.person(Role.ADMIN)
    assert (
        client.delete(f"/v1/admin/webhooks/{hook['id']}", headers=other_admin.headers).status_code
        == 404
    )


def test_transport_refuses_unsafe_targets_without_calling_them(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(net_guard, "resolve", lambda host: ["10.1.2.3"])
    # DNS now points inside: the real sender refuses before any connection.
    assert webhooks.transport("https://erp.example.com/hooks", {}, b"{}") == 0
