"""Step 6 end to end on the Google client libraries, against the local
stand-ins from docker-compose.yml (fake GCS server and the Pub/Sub emulator):

    docker compose up -d gcs pubsub

Endpoint 7 signs a V4 PUT URL with ``GcsStorage``; the bytes go straight to
the bucket; endpoint 8 checks them and writes the outbox event; the outbox
publishes through ``PubSubPublisher`` and a subscriber receives the message.

Skipped when the emulators aren't running. The fake server doesn't check
signatures or the size-range header, so those still need a real bucket.
"""

import json
import os
from collections.abc import Iterator
from contextlib import nullcontext
from urllib.parse import urlsplit

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.db.models import EvidenceFile
from app.enums import EvidenceStatus, Role
from app.ids import new_id
from app.storage.backend import GcsStorage
from app.worker.queue import PubSubPublisher, Queue, dispatch_outbox
from tests import samples
from tests.factories import Factory

GCS = "http://localhost:4443"
PUBSUB = "localhost:8085"
PROJECT = "pruflo-local"


def _up(url: str) -> bool:
    try:
        httpx.get(url, timeout=1)
    except httpx.HTTPError:
        return False
    return True


EMULATORS_UP = _up(f"{GCS}/storage/v1/b") and _up(f"http://{PUBSUB}")
if not EMULATORS_UP and os.environ.get("PRUFLO_REQUIRE_EMULATORS"):
    raise RuntimeError("PRUFLO_REQUIRE_EMULATORS is set but the emulators aren't reachable.")
pytestmark = pytest.mark.skipif(
    not EMULATORS_UP, reason="needs the gcs and pubsub services from docker-compose.yml"
)


def _signing_credentials() -> object:
    """A throwaway service-account key: real V4 signing, no Google account."""
    from google.oauth2 import service_account

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return service_account.Credentials.from_service_account_info(  # type: ignore[no-untyped-call]
        {
            "type": "service_account",
            "client_email": "api@pruflo-local.iam.gserviceaccount.com",
            "private_key": pem,
            "token_uri": "https://oauth2.googleapis.com/token",
            "project_id": PROJECT,
        }
    )


@pytest.fixture
def gcs(monkeypatch: pytest.MonkeyPatch) -> GcsStorage:
    monkeypatch.setenv("STORAGE_EMULATOR_HOST", GCS)
    bucket = f"evidence-{new_id('b').lower().replace('_', '-')}"
    storage = GcsStorage(bucket)
    storage._client.create_bucket(bucket)
    credentials = _signing_credentials()
    monkeypatch.setattr(storage, "_signing_kwargs", lambda: {"credentials": credentials})
    return storage


@pytest.fixture
def pubsub(monkeypatch: pytest.MonkeyPatch) -> Iterator[tuple[PubSubPublisher, str]]:
    from google.cloud import pubsub_v1

    monkeypatch.setenv("PUBSUB_EMULATOR_HOST", PUBSUB)
    topic_id = f"evidence-jobs-{new_id('t').lower()}"
    publisher = PubSubPublisher(PROJECT, topic_id)
    publisher._client.create_topic(name=publisher._topic)
    subscriber = pubsub_v1.SubscriberClient()
    subscription = subscriber.subscription_path(PROJECT, topic_id + "-sub")
    subscriber.create_subscription(name=subscription, topic=publisher._topic)
    yield publisher, subscription
    subscriber.delete_subscription(subscription=subscription)
    publisher._client.delete_topic(topic=publisher._topic)


def test_upload_through_gcs_reaches_pubsub(
    client: TestClient,
    make: Factory,
    db: Session,
    gcs: GcsStorage,
    pubsub: tuple[PubSubPublisher, str],
) -> None:
    from google.cloud import pubsub_v1

    from app.storage.backend import get_storage
    from app.worker.queue import get_queue

    publisher, subscription = pubsub
    # Pub/Sub mode: the API publishes and nothing runs in-process.
    queue = Queue(lambda: nullcontext(db), publisher, gcs, None, inline=False)
    client.app.dependency_overrides[get_storage] = lambda: gcs  # type: ignore[attr-defined]
    client.app.dependency_overrides[get_queue] = lambda: queue  # type: ignore[attr-defined]

    alice = make.person(Role.INVESTIGATOR)
    case = make.case(alice.tenant, alice)
    data = samples.pdf(3)
    slot = client.post(
        f"/v1/cases/{case.id}/evidence/upload-url",
        headers=alice.headers,
        json={
            "file_name": "po.pdf",
            "size_bytes": len(data),
            "content_type": "application/pdf",
            "evidence_types": ["documents"],
        },
    ).json()
    url = urlsplit(slot["upload_url"])
    assert f"{url.scheme}://{url.netloc}" == GCS
    assert "X-Goog-Signature=" in url.query and "x-goog-content-length-range" in url.query
    assert slot["headers"]["x-goog-content-length-range"] == f"0,{25 * 1024 * 1024}"

    # The client uploads straight to storage, as the Flutter app does.
    put = httpx.put(slot["upload_url"], content=data, headers=slot["headers"])
    assert put.status_code == 200, put.text

    res = client.post(
        f"/v1/cases/{case.id}/evidence/{slot['evidence_id']}/complete", headers=alice.headers
    )
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "queued" and res.json()["page_count"] == 3
    evidence = db.get(EvidenceFile, slot["evidence_id"])
    assert evidence is not None and evidence.status == EvidenceStatus.QUEUED

    # Whatever the request's background kick didn't publish, the dispatcher does.
    dispatch_outbox(db, publisher)
    subscriber = pubsub_v1.SubscriberClient()
    received = subscriber.pull(subscription=subscription, max_messages=10, timeout=10)
    messages = [m.message for m in received.received_messages]
    process = [m for m in messages if m.attributes["type"] == "evidence.process"]
    assert len(process) == 1
    assert json.loads(process[0].data)["evidence_id"] == evidence.id
    assert process[0].attributes["tenant_id"] == alice.tenant.id

    # Endpoint 11: a short-lived signed GET URL serves the same bytes.
    view = client.get(
        f"/v1/cases/{case.id}/evidence/{evidence.id}/view-url", headers=alice.headers
    ).json()
    assert httpx.get(view["url"]).content == data


def test_incomplete_gcs_upload_is_refused(
    client: TestClient, make: Factory, gcs: GcsStorage
) -> None:
    from app.storage.backend import get_storage

    client.app.dependency_overrides[get_storage] = lambda: gcs  # type: ignore[attr-defined]
    alice = make.person(Role.INVESTIGATOR)
    case = make.case(alice.tenant, alice)
    slot = client.post(
        f"/v1/cases/{case.id}/evidence/upload-url",
        headers=alice.headers,
        json={
            "file_name": "po.pdf",
            "size_bytes": 10,
            "content_type": "application/pdf",
            "evidence_types": ["documents"],
        },
    ).json()
    res = client.post(
        f"/v1/cases/{case.id}/evidence/{slot['evidence_id']}/complete", headers=alice.headers
    )
    assert res.status_code == 409 and res.json()["error"]["code"] == "upload_incomplete"
