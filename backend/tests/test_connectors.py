"""Document sources (43-45): email inbox, Odoo, Google Drive and SharePoint.

External services are replaced by ``httpx.MockTransport`` handlers that
answer like the real APIs; every imported file goes through the same checks
as an upload.
"""

import base64
import json
from collections.abc import Callable
from email.message import EmailMessage
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.connectors import base, oauth
from app.connectors.sync import sync_due
from app.db.models import AuditEvent, Case, Connector, EvidenceFile
from app.enums import ConnectorStatus, EvidenceStatus, Role
from app.services import net_guard
from app.storage.backend import LocalStorage
from tests import samples
from tests.factories import Factory, Person

Handler = Callable[[httpx.Request], httpx.Response]
DOMAIN = "in.pruflo.test"
TOKEN = "inbound-test-token"


@pytest.fixture
def remote(monkeypatch: pytest.MonkeyPatch) -> Callable[[Handler], list[httpx.Request]]:
    """Route every outgoing connector call to a fake service; returns the calls made."""
    monkeypatch.setattr(net_guard, "resolve", lambda host: ["93.184.216.34"])

    def install(handler: Handler) -> list[httpx.Request]:
        calls: list[httpx.Request] = []

        def record(request: httpx.Request) -> httpx.Response:
            calls.append(request)
            return handler(request)

        monkeypatch.setattr(
            base,
            "http_client",
            lambda: httpx.Client(transport=httpx.MockTransport(record), follow_redirects=False),
        )
        return calls

    return install


@pytest.fixture
def configured(monkeypatch: pytest.MonkeyPatch) -> None:
    settings = get_settings()
    for name, value in {
        "inbound_email_domain": DOMAIN,
        "inbound_email_token": TOKEN,
        "inbound_authserv_id": "mx.pruflo.test",
        "google_oauth_client_id": "google-client",
        "google_oauth_client_secret": "google-secret",
        "microsoft_oauth_client_id": "ms-client",
        "microsoft_oauth_client_secret": "ms-secret",
    }.items():
        monkeypatch.setattr(settings, name, value)


def _statuses(client: TestClient, admin: Person) -> dict[str, str]:
    items = client.get("/v1/admin/connectors", headers=admin.headers).json()["items"]
    return {i["kind"]: i["status"] for i in items}


# Listing and availability -------------------------------------------------------


def test_only_sources_this_deployment_can_run_are_offered(
    client: TestClient, make: Factory
) -> None:
    admin = make.person(Role.ADMIN)
    assert _statuses(client, admin) == {
        "email_inbox": "coming_soon",  # no inbound mail domain configured
        "google_drive": "coming_soon",  # no OAuth app
        "sharepoint": "coming_soon",
        "odoo": "not_connected",  # needs nothing but outbound HTTPS
        "sap": "coming_soon",  # no importer
    }
    res = client.put("/v1/admin/connectors/sap", headers=admin.headers, json={})
    assert res.status_code == 400 and res.json()["error"]["code"] == "connector_not_available"
    res = client.put("/v1/admin/connectors/email_inbox", headers=admin.headers, json={})
    assert res.json()["error"]["code"] == "connector_not_available"
    assert client.put("/v1/admin/connectors/fax", headers=admin.headers, json={}).status_code == 400


def test_configured_sources_are_offered(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    statuses = _statuses(client, admin)
    assert statuses.pop("sap") == "coming_soon"
    assert set(statuses.values()) == {"not_connected"}


def test_sources_are_admin_only(client: TestClient, make: Factory, configured: None) -> None:
    reviewer = make.person(Role.REVIEWER)
    investigator = make.person(Role.INVESTIGATOR, reviewer.tenant)
    assert client.get("/v1/admin/connectors", headers=reviewer.headers).status_code == 403
    res = client.put("/v1/admin/connectors/email_inbox", headers=investigator.headers, json={})
    assert res.status_code == 403


# Email inbox -------------------------------------------------------------------


def _enable_email(client: TestClient, admin: Person) -> str:
    res = client.put("/v1/admin/connectors/email_inbox", headers=admin.headers, json={})
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "connected"
    return str(res.json()["detail"])


def _mail(
    to: str,
    sender: str,
    subject: str,
    files: dict[str, bytes],
    *,
    auth: str | None = None,
    message_id: str = "<m1@example.com>",
) -> bytes:
    message = EmailMessage()
    domain = sender.rpartition("@")[2]
    if auth is None:
        auth = f"mx.pruflo.test; spf=pass smtp.mailfrom={sender}; dkim=pass header.d={domain}"
    if auth:
        message["Authentication-Results"] = auth
    message["From"] = f"Sender <{sender}>"
    message["To"] = to
    message["Subject"] = subject
    message["Message-ID"] = message_id
    message.set_content("See attached.")
    for name, data in files.items():
        maintype, subtype = ("application", "pdf") if name.endswith(".pdf") else ("text", "plain")
        if maintype == "text":
            message.add_attachment(data.decode(), subtype=subtype, filename=name)
        else:
            message.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
    return message.as_bytes()


def _post_mail(client: TestClient, raw: bytes, token: str = TOKEN) -> httpx.Response:
    return client.post(
        "/v1/inbound/email",
        content=raw,
        headers={"Content-Type": "message/rfc822", "X-Pruflo-Inbound-Token": token},
    )


def test_email_inbox_gets_a_stable_unguessable_address(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    local, _, domain = address.partition("@")
    assert domain == DOMAIN and local.startswith("evidence+acme-") and len(local) >= 20
    assert _enable_email(client, admin) == address  # reconnecting keeps it


def test_emailed_attachments_open_a_case_and_are_queued(
    client: TestClient, make: Factory, db: Session, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    investigator = make.person(Role.INVESTIGATOR, admin.tenant)
    address = _enable_email(client, admin)
    raw = _mail(
        address,
        investigator.user.email,
        "Delivery dispute Acme",
        {"po.pdf": samples.pdf(2), "delivery.csv": samples.CSV, "notes.zip": b"PK\x03\x04"},
    )
    res = _post_mail(client, raw)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["accepted"] and body["imported"] == 2 and body["skipped"] == 1
    case = db.get(Case, body["case_id"])
    assert case is not None and case.title == "Delivery dispute Acme"
    assert case.created_by == investigator.user.id
    files = db.scalars(select(EvidenceFile).where(EvidenceFile.case_id == case.id)).all()
    assert sorted(f.original_filename for f in files) == ["delivery.csv", "po.pdf"]
    for f in files:
        assert f.source == "email_inbox" and f.uploaded_by == investigator.user.id
        assert f.sha256 and f.status not in (EvidenceStatus.UPLOADING,)
    # The sender can see the case it opened.
    assert client.get(f"/v1/cases/{case.id}", headers=investigator.headers).status_code == 200
    # The same message delivered again imports nothing new.
    again = _post_mail(client, raw).json()
    assert again["imported"] == 0 and again["case_id"] == case.id


def test_subject_reference_adds_to_an_existing_case(
    client: TestClient, make: Factory, db: Session, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    case = make.case(admin.tenant, admin)
    raw = _mail(
        address, admin.user.email, f"Re: invoice [{case.reference}]", {"inv.pdf": samples.pdf()}
    )
    body = _post_mail(client, raw).json()
    assert body["case_id"] == case.id and body["imported"] == 1


def test_case_reference_the_sender_cant_see_opens_a_new_case(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    outsider = make.person(Role.INVESTIGATOR, admin.tenant)
    address = _enable_email(client, admin)
    private = make.case(admin.tenant, admin)
    raw = _mail(address, outsider.user.email, f"[{private.reference}]", {"x.pdf": samples.pdf()})
    body = _post_mail(client, raw).json()
    assert body["accepted"] and body["case_id"] != private.id


def test_wrong_files_are_kept_as_rejected_like_uploads(
    client: TestClient, make: Factory, db: Session, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    raw = _mail(address, admin.user.email, "Scan", {"fake.pdf": b"not a pdf at all"})
    body = _post_mail(client, raw).json()
    rejected = db.scalar(select(EvidenceFile).where(EvidenceFile.case_id == body["case_id"]))
    assert rejected is not None
    assert rejected.status == EvidenceStatus.FAILED_TERMINAL
    assert rejected.error_class == "unsupported_file"


@pytest.mark.parametrize(
    ("auth", "reason"),
    [
        ("", "sender_not_verified"),  # no Authentication-Results at all
        ("mx.pruflo.test; spf=fail smtp.mailfrom=x@acme.com; dkim=none", "sender_not_verified"),
        # DKIM passed, but for someone else's domain.
        ("mx.pruflo.test; dkim=pass header.d=attacker.example", "sender_not_verified"),
        # A header added by some other server isn't trusted.
        ("evil.example; dmarc=pass header.from=example.com", "sender_not_verified"),
        ("mx.pruflo.test; dmarc=pass header.from=example.com", ""),
    ],
)
def test_sender_must_be_verified(
    client: TestClient, make: Factory, configured: None, auth: str, reason: str
) -> None:
    admin = make.person(Role.ADMIN)  # emails are @example.com
    address = _enable_email(client, admin)
    raw = _mail(address, admin.user.email, "Docs", {"a.pdf": samples.pdf()}, auth=auth)
    body = _post_mail(client, raw).json()
    assert body["reason"] == reason and body["accepted"] == (not reason)


def test_forged_header_below_the_real_one_is_ignored(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    raw = _mail(address, admin.user.email, "Docs", {"a.pdf": samples.pdf()}, auth="")
    # The sender added a passing header; our server's (failing) one sits on top.
    forged = b"Authentication-Results: mx.pruflo.test; dmarc=pass header.from=example.com\r\n"
    real = b"Authentication-Results: mx.pruflo.test; dmarc=fail header.from=example.com\r\n"
    body = _post_mail(client, real + forged + raw).json()
    assert body["reason"] == "sender_not_verified"


def test_only_members_who_can_upload_may_send(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    viewer = make.person(Role.VIEWER, admin.tenant)
    stranger = make.person(Role.ADMIN)  # admin of another organisation
    address = _enable_email(client, admin)
    for person in (viewer, stranger):
        raw = _mail(address, person.user.email, "Docs", {"a.pdf": samples.pdf()})
        assert _post_mail(client, raw).json()["reason"] == "sender_not_allowed"


def test_inbound_needs_the_token_and_a_known_address(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    raw = _mail(address, admin.user.email, "Docs", {"a.pdf": samples.pdf()})
    assert _post_mail(client, raw, token="wrong").status_code == 401
    unknown = _mail(f"evidence+nobody@{DOMAIN}", admin.user.email, "Docs", {"a.pdf": samples.pdf()})
    assert _post_mail(client, unknown).json()["reason"] == "unknown_recipient"
    # After disconnecting, the address stops working.
    client.delete("/v1/admin/connectors/email_inbox", headers=admin.headers)
    assert _post_mail(client, raw).json()["reason"] == "unknown_recipient"


def test_inbound_accepts_sendgrid_form_posts(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    address = _enable_email(client, admin)
    raw = _mail(address, admin.user.email, "Docs", {"a.pdf": samples.pdf()})
    res = client.post(
        f"/v1/inbound/email?token={TOKEN}",
        files={"email": ("", raw)},
        data={"envelope": json.dumps({"to": [address], "from": admin.user.email})},
    )
    assert res.status_code == 200 and res.json()["imported"] == 1


def test_inbound_is_off_without_configuration(client: TestClient) -> None:
    assert _post_mail(client, b"x").status_code == 404


# Odoo ----------------------------------------------------------------------------


class FakeOdoo:
    """Answers JSON-RPC like Odoo 17 for one read-only user."""

    def __init__(self) -> None:
        self.attachments: list[dict[str, Any]] = []
        self.records = {
            ("purchase.order", 7): {"id": 7, "name": "P00042"},
            ("stock.picking", 3): {"id": 3, "name": "WH/IN/00003", "origin": "P00042"},
            ("account.move", 9): {
                "id": 9,
                "name": "BILL/2026/0009",
                "invoice_origin": "P00042",
                "move_type": "in_invoice",
            },
            ("account.move", 10): {
                "id": 10,
                "name": "INV/2026/0010",
                "invoice_origin": "S0001",
                "move_type": "out_invoice",
            },
        }
        self.api_key = "good-key"

    def add(self, id_: int, name: str, model: str, res_id: int, data: bytes) -> None:
        self.attachments.append(
            {
                "id": id_,
                "name": name,
                "res_model": model,
                "res_id": res_id,
                "file_size": len(data),
                "datas": base64.b64encode(data).decode(),
            }
        )

    def __call__(self, request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/jsonrpc"
        params = json.loads(request.content)["params"]
        service, method, args = params["service"], params["method"], params["args"]
        if service == "common" and method == "authenticate":
            return self._ok(5 if args[2] == self.api_key else False)
        _db, _uid, key, model, op, op_args, kwargs = args
        if key != self.api_key:
            return httpx.Response(
                200, json={"error": {"data": {"name": "odoo.exceptions.AccessDenied"}}}
            )
        if model == "ir.attachment" and op == "search_read":
            domain = op_args[0]
            after = next((d[2] for d in domain if d[0] == "id"), 0)
            rows = sorted(
                self.attachments, key=lambda a: a["id"], reverse=kwargs.get("order") == "id desc"
            )
            rows = [
                {k: v for k, v in a.items() if k in kwargs["fields"]}
                for a in rows
                if a["id"] > after
            ]
            return self._ok(rows[: kwargs.get("limit", 80)])
        if model == "ir.attachment" and op == "read":
            return self._ok(
                [
                    {"id": a["id"], "datas": a["datas"]}
                    for a in self.attachments
                    if a["id"] in op_args[0]
                ]
            )
        if op == "read":
            return self._ok([self.records[(model, i)] for i in op_args[0]])
        raise AssertionError(f"unexpected call {model}.{op}")

    @staticmethod
    def _ok(result: Any) -> httpx.Response:
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "result": result})


ODOO_BODY = {
    "url": "https://acme.odoo.com",
    "database": "acme",
    "username": "pruflo",
    "api_key": "good-key",
}


def test_odoo_checks_the_login_before_saving(
    client: TestClient, make: Factory, db: Session, remote: Any
) -> None:
    odoo = FakeOdoo()
    remote(odoo)
    admin = make.person(Role.ADMIN)
    res = client.put(
        "/v1/admin/connectors/odoo", headers=admin.headers, json={**ODOO_BODY, "api_key": "bad"}
    )
    assert res.status_code == 400
    assert res.json()["error"]["message"] == "Odoo rejected the username or API key."
    res = client.put("/v1/admin/connectors/odoo", headers=admin.headers, json=ODOO_BODY)
    assert res.status_code == 200, res.text
    assert res.json() == {**res.json(), "status": "connected", "detail": "https://acme.odoo.com"}
    assert "good-key" not in res.text
    row = db.scalar(select(Connector).where(Connector.tenant_id == admin.tenant.id))
    assert row is not None and row.secret and "good-key" not in row.secret
    assert "good-key" not in client.get("/v1/admin/connectors", headers=admin.headers).text


def test_odoo_urls_must_be_public_https(
    client: TestClient, make: Factory, remote: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    remote(FakeOdoo())
    admin = make.person(Role.ADMIN)
    for url in ("http://acme.odoo.com", "https://localhost:8069"):
        res = client.put(
            "/v1/admin/connectors/odoo", headers=admin.headers, json={**ODOO_BODY, "url": url}
        )
        assert res.status_code == 400, url
    monkeypatch.setattr(net_guard, "resolve", lambda host: ["10.0.0.5"])
    res = client.put("/v1/admin/connectors/odoo", headers=admin.headers, json=ODOO_BODY)
    assert res.status_code == 400 and "private" in res.json()["error"]["message"]


def test_odoo_sync_imports_new_order_documents_into_one_case(
    client: TestClient, make: Factory, db: Session, storage: LocalStorage, remote: Any
) -> None:
    odoo = FakeOdoo()
    odoo.add(1, "old.pdf", "purchase.order", 7, samples.pdf())  # before connecting
    remote(odoo)
    admin = make.person(Role.ADMIN)
    client.put("/v1/admin/connectors/odoo", headers=admin.headers, json=ODOO_BODY)
    odoo.add(2, "PO P00042.pdf", "purchase.order", 7, samples.pdf())
    odoo.add(3, "receipt.pdf", "stock.picking", 3, samples.pdf())
    odoo.add(4, "bill.pdf", "account.move", 9, samples.pdf())
    odoo.add(5, "customer-invoice.pdf", "account.move", 10, samples.pdf())  # not a vendor bill
    odoo.add(6, "einvoice.xml", "account.move", 9, b"<xml/>")  # a type Pruflo never reads

    totals = sync_due(db, storage)
    assert totals == {"connectors": 1, "imported": 3, "failed": 0}
    files = db.scalars(select(EvidenceFile).where(EvidenceFile.tenant_id == admin.tenant.id)).all()
    assert sorted(f.original_filename for f in files) == [
        "PO P00042.pdf",
        "bill.pdf",
        "receipt.pdf",
    ]
    assert len({f.case_id for f in files}) == 1
    case = db.get(Case, files[0].case_id)
    assert case is not None and case.title == "Odoo P00042" and case.created_by == admin.user.id
    assert all(f.source == "odoo" and f.status != EvidenceStatus.UPLOADING for f in files)
    # Not due again yet, and forcing it finds nothing new.
    assert sync_due(db, storage)["connectors"] == 0
    assert sync_due(db, storage, force=True)["imported"] == 0
    odoo.add(7, "credit-note.pdf", "account.move", 9, samples.pdf())
    assert sync_due(db, storage, force=True)["imported"] == 1
    assert (
        db.scalar(
            select(EvidenceFile.case_id).where(EvidenceFile.original_filename == "credit-note.pdf")
        )
        == case.id
    )


def test_odoo_failure_shows_a_readable_error_then_recovers(
    client: TestClient, make: Factory, db: Session, storage: LocalStorage, remote: Any
) -> None:
    odoo = FakeOdoo()
    remote(odoo)
    admin = make.person(Role.ADMIN)
    client.put("/v1/admin/connectors/odoo", headers=admin.headers, json=ODOO_BODY)
    odoo.api_key = "rotated"
    assert sync_due(db, storage)["failed"] == 1
    item = next(
        i
        for i in client.get("/v1/admin/connectors", headers=admin.headers).json()["items"]
        if i["kind"] == "odoo"
    )
    assert item["status"] == "error" and item["detail"] == "Odoo rejected the username or API key."
    odoo.api_key = "good-key"
    sync_due(db, storage, force=True)
    assert _statuses(client, admin)["odoo"] == "connected"


# Google Drive and SharePoint ------------------------------------------------------


def _start(client: TestClient, admin: Person, kind: str, folder: str) -> dict[str, list[str]]:
    res = client.put(
        f"/v1/admin/connectors/{kind}",
        headers=admin.headers,
        json={"folder": folder, "return_url": "https://pruflo.web.app/integrations"},
    )
    assert res.status_code == 200, res.text
    return parse_qs(urlsplit(res.json()["authorization_url"]).query)


class FakeGoogle:
    def __init__(self) -> None:
        self.files: dict[str, dict[str, Any]] = {
            "1RootFolderAbc_x": {
                "id": "1RootFolderAbc_x",
                "name": "Evidence",
                "mimeType": "application/vnd.google-apps.folder",
            },
        }
        self.content: dict[str, bytes] = {}
        self.refresh_ok = True

    def add(
        self,
        id_: str,
        name: str,
        parent: str,
        data: bytes | None = None,
        mime: str = "application/pdf",
    ) -> None:
        self.files[id_] = {
            "id": id_,
            "name": name,
            "mimeType": mime,
            "parent": parent,
            "md5Checksum": f"md5-{id_}",
        }
        if data is not None:
            self.files[id_]["size"] = str(len(data))
            self.content[id_] = data

    def __call__(self, request: httpx.Request) -> httpx.Response:
        url = request.url
        if url.host == "oauth2.googleapis.com":
            form = parse_qs(request.content.decode())
            assert form["client_secret"] == ["google-secret"]
            if form["grant_type"] == ["authorization_code"]:
                assert form["code"] == ["the-code"]
                return httpx.Response(200, json={"access_token": "at", "refresh_token": "rt-1"})
            if not self.refresh_ok:
                return httpx.Response(400, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"access_token": "at2"})
        assert request.headers["Authorization"].startswith("Bearer at")
        if url.path == "/drive/v3/files":
            parent = url.params["q"].split("'")[1]
            children = [
                {k: v for k, v in f.items() if k != "parent"}
                for f in self.files.values()
                if f.get("parent") == parent
            ]
            return httpx.Response(200, json={"files": children})
        file_id = url.path.split("/")[4]
        if url.path.endswith("/export"):
            return httpx.Response(200, content=samples.pdf())
        if url.params.get("alt") == "media":
            return httpx.Response(200, content=self.content[file_id])
        if file_id not in self.files:
            return httpx.Response(404)
        return httpx.Response(200, json=self.files[file_id])


def _consent(
    client: TestClient, query: dict[str, list[str]], code: str = "the-code"
) -> httpx.Response:
    return client.get(
        "/v1/connectors/oauth/callback",
        params={"state": query["state"][0], "code": code},
        follow_redirects=False,
    )


def test_drive_oauth_round_trip(
    client: TestClient, make: Factory, db: Session, configured: None, remote: Any
) -> None:
    google = FakeGoogle()
    remote(google)
    admin = make.person(Role.ADMIN)
    query = _start(
        client,
        admin,
        "google_drive",
        "https://drive.google.com/drive/folders/1RootFolderAbc_x?usp=sharing",
    )
    assert query["client_id"] == ["google-client"]
    assert query["scope"] == ["https://www.googleapis.com/auth/drive.readonly"]
    assert query["redirect_uri"] == [oauth.redirect_uri()]
    assert _statuses(client, admin)["google_drive"] == "not_connected"  # until consent

    res = _consent(client, query)
    assert res.status_code == 303
    assert res.headers["location"] == (
        "https://pruflo.web.app/integrations?connector=google_drive&status=connected"
    )
    items = client.get("/v1/admin/connectors", headers=admin.headers).json()["items"]
    drive = next(i for i in items if i["kind"] == "google_drive")
    assert drive["status"] == "connected" and drive["detail"] == "Evidence"
    row = db.scalar(
        select(Connector).where(
            Connector.kind == "google_drive", Connector.tenant_id == admin.tenant.id
        )
    )
    assert row is not None and row.secret and "rt-1" not in row.secret
    assert db.scalar(
        select(AuditEvent).where(
            AuditEvent.action == "connector.connected", AuditEvent.actor_user_id == admin.user.id
        )
    )
    # The state works once.
    again = _consent(client, query)
    assert "status=error" in again.headers["location"]


def test_drive_callback_rejects_tampered_or_foreign_state(
    client: TestClient, make: Factory, configured: None, remote: Any
) -> None:
    remote(FakeGoogle())
    admin = make.person(Role.ADMIN)
    query = _start(client, admin, "google_drive", "1RootFolderAbc_x")
    body, _, signature = query["state"][0].partition(".")
    res = client.get(
        "/v1/connectors/oauth/callback",
        params={"state": body + "x." + signature, "code": "c"},
        follow_redirects=False,
    )
    assert res.status_code == 400
    res = client.get("/v1/connectors/oauth/callback", params={"state": "", "code": "c"})
    assert res.status_code == 400


def test_return_url_must_be_the_web_app(
    client: TestClient, make: Factory, configured: None
) -> None:
    admin = make.person(Role.ADMIN)
    res = client.put(
        "/v1/admin/connectors/google_drive",
        headers=admin.headers,
        json={"folder": "1RootFolderAbc_x", "return_url": "https://evil.example/steal"},
    )
    assert res.status_code == 400 and "return_url" in res.json()["error"]["message"]
    res = client.put(
        "/v1/admin/connectors/google_drive",
        headers=admin.headers,
        json={"folder": "https://example.com/folders/x", "return_url": "https://pruflo.web.app/i"},
    )
    assert res.status_code == 400
    # Folder IDs go into a Drive query, so nothing but ID characters.
    res = client.put(
        "/v1/admin/connectors/google_drive",
        headers=admin.headers,
        json={"folder": "x' or 'a' in parents or '", "return_url": "https://pruflo.web.app/i"},
    )
    assert res.status_code == 400


def test_drive_denied_consent_goes_back_with_an_error(
    client: TestClient, make: Factory, configured: None, remote: Any
) -> None:
    remote(FakeGoogle())
    admin = make.person(Role.ADMIN)
    query = _start(client, admin, "google_drive", "1RootFolderAbc_x")
    res = client.get(
        "/v1/connectors/oauth/callback",
        params={"state": query["state"][0], "error": "access_denied"},
        follow_redirects=False,
    )
    assert "connector=google_drive&status=error" in res.headers["location"]


def test_drive_sync_groups_subfolders_into_cases(
    client: TestClient,
    make: Factory,
    db: Session,
    storage: LocalStorage,
    configured: None,
    remote: Any,
) -> None:
    google = FakeGoogle()
    remote(google)
    admin = make.person(Role.ADMIN)
    existing = make.case(admin.tenant, admin)
    google.add(
        "sub1", "Supplier X dispute", "1RootFolderAbc_x", mime="application/vnd.google-apps.folder"
    )
    google.add(
        "sub2",
        f"More for {existing.reference}",
        "1RootFolderAbc_x",
        mime="application/vnd.google-apps.folder",
    )
    google.add("deep", "scans", "sub1", mime="application/vnd.google-apps.folder")
    google.add("f1", "po.pdf", "sub1", samples.pdf())
    google.add("f2", "receipt.pdf", "deep", samples.pdf())
    google.add("f3", "loose.csv", "1RootFolderAbc_x", samples.CSV)
    google.add("f4", "invoice.pdf", "sub2", samples.pdf())
    google.add("f5", "Delivery notes", "sub1", mime="application/vnd.google-apps.document")
    google.add("f6", "slides", "sub1", mime="application/vnd.google-apps.presentation")
    google.add("f7", "huge.pdf", "sub1")
    google.files["f7"]["size"] = str(30 * 1024 * 1024)
    google.add("f8", "archive.zip", "1RootFolderAbc_x", b"PK")

    query = _start(client, admin, "google_drive", "1RootFolderAbc_x")
    _consent(client, query)
    totals = sync_due(db, storage)
    assert totals["imported"] == 6 and totals["failed"] == 0  # huge.pdf is recorded as rejected
    files = {
        f.original_filename: f
        for f in db.scalars(select(EvidenceFile).where(EvidenceFile.tenant_id == admin.tenant.id))
    }
    assert set(files) == {
        "po.pdf",
        "receipt.pdf",
        "loose.csv",
        "invoice.pdf",
        "Delivery notes.pdf",
        "huge.pdf",
    }
    assert (
        files["po.pdf"].case_id
        == files["receipt.pdf"].case_id
        == files["Delivery notes.pdf"].case_id
    )
    assert files["invoice.pdf"].case_id == existing.id
    assert files["loose.csv"].case_id not in (files["po.pdf"].case_id, existing.id)
    assert files["huge.pdf"].error_class == "file_too_large"
    assert not storage.path(files["huge.pdf"].object_key).exists()
    folder_case = db.get(Case, files["po.pdf"].case_id)
    assert folder_case is not None and folder_case.title == "Supplier X dispute"
    # Nothing new: nothing imported. A changed file comes in as new evidence.
    assert sync_due(db, storage, force=True)["imported"] == 0
    google.files["f1"]["md5Checksum"] = "md5-changed"
    assert sync_due(db, storage, force=True)["imported"] == 1


def test_drive_revoked_access_shows_an_error(
    client: TestClient,
    make: Factory,
    db: Session,
    storage: LocalStorage,
    configured: None,
    remote: Any,
) -> None:
    google = FakeGoogle()
    remote(google)
    admin = make.person(Role.ADMIN)
    _consent(client, _start(client, admin, "google_drive", "1RootFolderAbc_x"))
    google.refresh_ok = False
    sync_due(db, storage)
    row = db.scalar(
        select(Connector).where(
            Connector.kind == "google_drive", Connector.tenant_id == admin.tenant.id
        )
    )
    assert row is not None and row.status == ConnectorStatus.ERROR
    assert row.detail == "Access was withdrawn. Connect it again."


GRAPH = "https://graph.microsoft.com/v1.0"
CHILDREN = "$select=id,name,size,file,folder,lastModifiedDateTime,eTag&$top=200"


class FakeGraph:
    def __call__(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if request.url.host == "login.microsoftonline.com":
            form = parse_qs(request.content.decode())
            assert form["scope"] == ["https://graph.microsoft.com/Sites.Selected offline_access"]
            return httpx.Response(200, json={"access_token": "at", "refresh_token": "rt"})
        if request.url.host == "acme.sharepoint.com":
            # The pre-authenticated download link Graph redirects to.
            assert "Authorization" not in request.headers
            return httpx.Response(200, content=samples.pdf())
        assert request.headers["Authorization"] == "Bearer at"
        routes: dict[str, Any] = {
            f"{GRAPH}/sites/acme.sharepoint.com:/sites/Finance": {"id": "site1"},
            f"{GRAPH}/sites/site1/drives?$select=id,name,webUrl": {
                "value": [
                    {
                        "id": "drv1",
                        "name": "Documents",
                        "webUrl": "https://acme.sharepoint.com/sites/Finance/Shared%20Documents",
                    },
                ]
            },
            f"{GRAPH}/drives/drv1/root:/Evidence": {"id": "itm1", "name": "Evidence", "folder": {}},
            f"{GRAPH}/drives/drv1/items/itm1/children?{CHILDREN}": {
                "value": [
                    {"id": "a", "name": "Case 1", "folder": {}},
                    {
                        "id": "b",
                        "name": "loose.pdf",
                        "size": 10,
                        "file": {"hashes": {"quickXorHash": "h"}},
                    },
                ],
            },
            f"{GRAPH}/drives/drv1/items/a/children?{CHILDREN}": {
                "value": [{"id": "c", "name": "po.pdf", "size": 10, "file": {}, "eTag": "e1"}],
            },
        }
        if url.endswith("/content"):
            return httpx.Response(
                302, headers={"Location": "https://acme.sharepoint.com/download?x=1"}
            )
        if url in routes:
            return httpx.Response(200, json=routes[url])
        raise AssertionError(f"unexpected Graph call {url}")


def test_sharepoint_library_link_is_resolved_and_synced(
    client: TestClient,
    make: Factory,
    db: Session,
    storage: LocalStorage,
    configured: None,
    remote: Any,
) -> None:
    remote(FakeGraph())
    admin = make.person(Role.ADMIN)
    link = "https://acme.sharepoint.com/sites/Finance/Shared%20Documents/Evidence"
    query = _start(client, admin, "sharepoint", link)
    assert query["scope"] == ["https://graph.microsoft.com/Sites.Selected offline_access"]
    res = _consent(client, query)
    assert res.headers["location"].endswith("connector=sharepoint&status=connected")
    assert sync_due(db, storage)["imported"] == 2
    files = db.scalars(select(EvidenceFile).where(EvidenceFile.tenant_id == admin.tenant.id)).all()
    assert sorted(f.original_filename for f in files) == ["loose.pdf", "po.pdf"]
    assert all(f.source == "sharepoint" for f in files)
