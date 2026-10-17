"""Odoo: attachments on purchase orders, receipts and vendor bills become evidence.

Connecting checks the login (``common.authenticate`` over JSON-RPC) and that
the user can read attachments. Each sync then reads attachments newer than
the last one seen. Import starts from the moment of connecting, not from the
database's history.

Files are grouped by purchase order: a receipt's ``origin`` and a bill's
``invoice_origin`` name the order, so an order's documents land in one case.
Customer invoices are skipped. The Odoo URL is checked against private and
reserved addresses on save and before every sync, like webhook URLs.
"""

import base64
import binascii
import itertools
from typing import Any

import httpx
from sqlalchemy.orm import Session

from app.config import MAX_FILE_BYTES
from app.connectors import base
from app.connectors.base import ConnectorFailed, case_for, credentials
from app.db.models import Connector
from app.enums import EvidenceSource
from app.services import net_guard
from app.services.evidence import import_file
from app.storage import file_types
from app.storage.backend import Storage

MODELS = ("purchase.order", "stock.picking", "account.move")
VENDOR_BILLS = ("in_invoice", "in_refund")
BATCH = 50
_ids = itertools.count(1)


class Odoo:
    def __init__(self, url: str, database: str, username: str, api_key: str) -> None:
        try:
            self.url = net_guard.check_url(url).rstrip("/")
        except net_guard.UnsafeUrl as exc:
            raise ConnectorFailed(f"That Odoo URL can't be used: {exc}") from exc
        self.database = database
        self.username = username
        self.api_key = api_key
        self.uid: int | None = None

    def _call(self, service: str, method: str, *args: Any) -> Any:
        body = {
            "jsonrpc": "2.0",
            "method": "call",
            "id": next(_ids),
            "params": {"service": service, "method": method, "args": list(args)},
        }
        try:
            with base.http_client() as client:
                response = client.post(f"{self.url}/jsonrpc", json=body)
        except httpx.HTTPError as exc:
            raise ConnectorFailed("Odoo couldn't be reached. Check the URL.") from exc
        if response.status_code != 200:
            raise ConnectorFailed(f"Odoo answered with HTTP {response.status_code}.")
        try:
            reply = response.json()
        except ValueError as exc:
            raise ConnectorFailed("That URL didn't answer like an Odoo server.") from exc
        if "error" in reply:
            error = reply["error"].get("data", {}) or {}
            name = str(error.get("name", ""))
            if "AccessDenied" in name or "AccessError" in name:
                raise ConnectorFailed("Odoo refused access for this user.")
            if "database" in str(error.get("message", "")).lower():
                raise ConnectorFailed("Odoo doesn't have that database.")
            raise ConnectorFailed("Odoo returned an error.")
        return reply.get("result")

    def login(self) -> int:
        uid = self._call("common", "authenticate", self.database, self.username, self.api_key, {})
        if not uid:
            raise ConnectorFailed("Odoo rejected the username or API key.")
        self.uid = int(uid)
        return self.uid

    def execute(self, model: str, method: str, args: list[Any], **kwargs: Any) -> Any:
        if self.uid is None:
            self.login()
        return self._call(
            "object",
            "execute_kw",
            self.database,
            self.uid,
            self.api_key,
            model,
            method,
            args,
            kwargs,
        )


def _client(connector: Connector) -> Odoo:
    creds = credentials(connector)
    return Odoo(creds["url"], creds["database"], creds["username"], creds["api_key"])


def connect(values: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Check the login and access. Returns (credentials to store, starting state)."""
    missing = [k for k in ("url", "database", "username", "api_key") if not str(values.get(k, ""))]
    if missing:
        raise ConnectorFailed(f"Fill in {', '.join(missing)}.")
    creds = {k: str(values[k]).strip() for k in ("url", "database", "username", "api_key")}
    odoo = Odoo(**creds)
    uid = odoo.login()
    newest = odoo.execute(
        "ir.attachment",
        "search_read",
        [[("res_model", "in", list(MODELS))]],
        fields=["id"],
        order="id desc",
        limit=1,
    )
    if not isinstance(newest, list):
        raise ConnectorFailed("This Odoo user can't read attachments.")
    creds["url"] = odoo.url
    return creds, {"uid": uid, "last_attachment_id": newest[0]["id"] if newest else 0}


def _order_names(odoo: Odoo, model: str, ids: list[int]) -> dict[int, str | None]:
    """The purchase order each record belongs to; None to skip the record."""
    if model == "purchase.order":
        rows = odoo.execute(model, "read", [ids], fields=["name"])
        return {r["id"]: r["name"] for r in rows}
    if model == "stock.picking":
        rows = odoo.execute(model, "read", [ids], fields=["name", "origin"])
        return {r["id"]: r.get("origin") or r["name"] for r in rows}
    rows = odoo.execute(model, "read", [ids], fields=["name", "invoice_origin", "move_type"])
    return {
        r["id"]: (
            (r.get("invoice_origin") or r["name"]).split(",")[0].strip()
            if r.get("move_type") in VENDOR_BILLS
            else None
        )
        for r in rows
    }


def sync(db: Session, storage: Storage, connector: Connector) -> int:
    odoo = _client(connector)
    odoo.login()
    last = int(connector.state.get("last_attachment_id", 0))
    attachments = odoo.execute(
        "ir.attachment",
        "search_read",
        [[("res_model", "in", list(MODELS)), ("id", ">", last), ("type", "=", "binary")]],
        fields=["id", "name", "file_size", "res_model", "res_id"],
        order="id asc",
        limit=BATCH,
    )
    by_model: dict[str, list[int]] = {}
    for a in attachments:
        by_model.setdefault(a["res_model"], []).append(a["res_id"])
    orders = {
        (model, rid): name
        for model, ids in by_model.items()
        for rid, name in _order_names(odoo, model, sorted(set(ids))).items()
    }
    imported = 0
    for a in attachments:
        order = orders.get((a["res_model"], a["res_id"]))
        # Types Pruflo never reads, such as XML e-invoices, are passed over.
        if order and file_types.extension_of(a["name"]) in file_types.FILE_TYPES:
            case = case_for(db, connector, f"order:{order}", f"Odoo {order}", hint=a["name"])
            size = int(a.get("file_size") or 0)
            data: bytes | None = None
            if size <= MAX_FILE_BYTES:
                rows = odoo.execute("ir.attachment", "read", [[a["id"]]], fields=["datas"])
                try:
                    data = base64.b64decode(rows[0]["datas"] or b"")
                except (binascii.Error, IndexError, KeyError) as exc:
                    raise ConnectorFailed("Odoo sent an attachment that couldn't be read.") from exc
            if import_file(
                db,
                storage,
                case,
                file_name=a["name"],
                data=data,
                size=size,
                source=EvidenceSource.ODOO,
                source_ref=f"attachment:{a['id']}",
                uploaded_by=connector.connected_by,
            ):
                imported += 1
        connector.state = {**connector.state, "last_attachment_id": a["id"]}
        db.commit()
    return imported
