"""Email inbox: attachments sent to evidence+<tag>@<inbound domain> become evidence.

The mail service (SendGrid Inbound Parse in raw mode, a Mailgun route to a
``mime`` URL, or any relay) posts the full message to ``/v1/inbound/email``
with the shared token. Then:

1. The recipient address picks the organisation.
2. The sender must pass SPF or DKIM aligned with the From domain (or DMARC),
   according to the receiving server's Authentication-Results header, and
   must be an active member of that organisation who may upload evidence.
   Mail from anyone else is dropped: the address alone isn't a credential.
3. ``[PL-001]`` in the subject adds the attachments to that case (if the
   sender can see it); otherwise a new case is opened, titled by the subject.
4. Each attachment goes through the same checks as an upload.
"""

import hashlib
import logging
import re
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import getaddresses, parseaddr

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.permissions import ROLE_PERMISSIONS, Permission
from app.auth.principal import Principal, can_see_case
from app.config import get_settings
from app.db.models import Case, Connector, EvidenceFile, Membership, Tenant, User
from app.enums import ConnectorKind, ConnectorStatus, EvidenceSource, Role
from app.ids import new_id
from app.services import cases as case_service
from app.services.evidence import UploadRejected, import_file
from app.storage import file_types
from app.storage.backend import Storage

logger = logging.getLogger("pruflo.connectors.email")

MAX_MESSAGE_BYTES = 60 * 1024 * 1024
MAX_ATTACHMENTS = 20  # the same batch limit as uploads


@dataclass
class InboundResult:
    accepted: bool
    reason: str = ""
    case_id: str | None = None
    imported: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)


def connect(db: Session, connector: Connector, tenant: Tenant) -> None:
    """Give the organisation its address. Reconnecting keeps the old one."""
    settings = get_settings()
    if not connector.detail:
        slug = re.sub(r"[^a-z0-9]+", "-", tenant.name.lower()).strip("-")[:20] or "org"
        # The random part stops people guessing another organisation's address.
        tag = f"{slug}-{secrets.token_hex(3)}"
        connector.detail = f"evidence+{tag}@{settings.inbound_email_domain}"
    connector.status = ConnectorStatus.CONNECTED
    connector.connected_at = datetime.now(UTC)


def parse(raw: bytes) -> EmailMessage:
    # With policy.default the parser builds EmailMessage objects.
    return BytesParser(_class=EmailMessage, policy=policy.default).parsebytes(raw)


def _domain(address: str) -> str:
    return address.rpartition("@")[2].strip().lower().rstrip(".")


def _aligned(domain: str, from_domain: str) -> bool:
    """Relaxed alignment, as DMARC defines it: the same domain or a subdomain."""
    if "." not in domain or "." not in from_domain:
        return False
    return (
        domain == from_domain
        or from_domain.endswith("." + domain)
        or domain.endswith("." + from_domain)
    )


def sender_verified(message: EmailMessage, from_address: str) -> bool:
    """True when the receiving server vouched for the From domain.

    Only the topmost Authentication-Results header counts: it's the one our
    mail service added. Anything below it came with the message and could be
    forged. With ``inbound_authserv_id`` set, that header must also carry it.
    """
    headers = message.get_all("Authentication-Results") or []
    if not headers:
        return False
    results = str(headers[0])
    authserv = get_settings().inbound_authserv_id
    if authserv and results.split(";", 1)[0].strip().lower() != authserv.lower():
        return False
    from_domain = _domain(from_address)
    for clause in results.split(";")[1:]:
        clause = clause.strip().lower()
        method = re.match(r"(dmarc|dkim|spf)\s*=\s*(\w+)", clause)
        if not method or method.group(2) != "pass":
            continue
        kind = method.group(1)
        if kind == "dmarc":
            found = re.search(r"header\.from\s*=\s*([^\s;]+)", clause)
            if found is None or _aligned(found.group(1), from_domain):
                return True
        elif kind == "dkim":
            found = re.search(r"header\.(?:d|i)\s*=\s*@?([^\s;]+)", clause)
            if found and _aligned(_domain(found.group(1)), from_domain):
                return True
        else:
            found = re.search(r"smtp\.mailfrom\s*=\s*([^\s;]+)", clause)
            if found and _aligned(_domain(found.group(1)), from_domain):
                return True
    return False


def _connector_for(db: Session, message: EmailMessage, envelope_to: list[str]) -> Connector | None:
    domain = get_settings().inbound_email_domain.lower()
    candidates = list(envelope_to)
    for header in ("Delivered-To", "X-Original-To", "To", "Cc"):
        candidates += [a for _, a in getaddresses([str(v) for v in message.get_all(header) or []])]
    for address in dict.fromkeys(a.strip().lower() for a in candidates if a):
        if _domain(address) != domain:
            continue
        connector = db.scalar(
            select(Connector).where(
                Connector.kind == ConnectorKind.EMAIL_INBOX,
                Connector.detail == address,
                Connector.status == ConnectorStatus.CONNECTED,
            )
        )
        if connector is not None:
            return connector
    return None


def _sender(db: Session, tenant_id: str, address: str) -> Principal | None:
    row = db.execute(
        select(User, Membership.role)
        .join(Membership, Membership.user_id == User.id)
        .where(User.email == address.lower(), User.active, Membership.tenant_id == tenant_id)
    ).first()
    if row is None:
        return None
    user, role_value = row
    role = Role(role_value)
    permissions = ROLE_PERMISSIONS[role]
    if Permission.UPLOAD_EVIDENCE not in permissions:
        return None
    return Principal(tenant_id=tenant_id, permissions=permissions, user=user, role=role)


def handle(
    db: Session, storage: Storage, raw: bytes, envelope_to: list[str] | None = None
) -> InboundResult:
    if len(raw) > MAX_MESSAGE_BYTES:
        return InboundResult(False, "message_too_large")
    message = parse(raw)
    connector = _connector_for(db, message, envelope_to or [])
    if connector is None:
        return InboundResult(False, "unknown_recipient")
    _, from_address = parseaddr(str(message.get("From", "")))
    if not from_address or not sender_verified(message, from_address):
        logger.warning("inbound mail for %s failed sender checks", connector.tenant_id)
        return InboundResult(False, "sender_not_verified")
    principal = _sender(db, connector.tenant_id, from_address)
    if principal is None:
        logger.warning("inbound mail for %s from a non-member", connector.tenant_id)
        return InboundResult(False, "sender_not_allowed")

    attachments = [part for part in message.iter_attachments() if isinstance(part, EmailMessage)]
    if not any(
        file_types.extension_of(p.get_filename() or "") in file_types.FILE_TYPES
        for p in attachments
    ):
        return InboundResult(False, "no_attachments")
    message_id = str(message.get("Message-ID", "")).strip() or new_id("msg")
    # The same message delivered twice imports nothing new.
    refs = [
        hashlib.sha256(f"{message_id}\n{i}".encode()).hexdigest() for i in range(len(attachments))
    ]
    subject = str(message.get("Subject", "")).strip()
    case = db.scalar(
        select(Case)
        .join(EvidenceFile, EvidenceFile.case_id == Case.id)
        .where(
            EvidenceFile.tenant_id == connector.tenant_id,
            EvidenceFile.source == EvidenceSource.EMAIL_INBOX,
            EvidenceFile.source_ref.in_(refs),
        )
        .limit(1)
    ) or case_service.find_by_reference(db, connector.tenant_id, subject)
    if case is not None and not can_see_case(db, principal, case):
        case = None
    if case is None:
        case = case_service.create_imported(
            db,
            connector.tenant_id,
            subject or f"Email from {from_address}",
            created_by=principal.user_id,
            source=ConnectorKind.EMAIL_INBOX,
            principal=principal,
        )
    result = InboundResult(True, case_id=case.id)
    for index, part in enumerate(attachments):
        name = (part.get_filename() or f"attachment-{index + 1}").strip()
        if index >= MAX_ATTACHMENTS:
            result.skipped.append(name)
            continue
        payload = part.get_payload(decode=True)
        data = payload if isinstance(payload, bytes) else b""
        try:
            evidence = import_file(
                db,
                storage,
                case,
                file_name=name,
                data=data,
                source=EvidenceSource.EMAIL_INBOX,
                source_ref=refs[index],
                principal=principal,
            )
        except UploadRejected:
            result.skipped.append(name)
            continue
        if evidence is not None:
            result.imported.append(evidence.id)
    connector.last_synced_at = datetime.now(UTC)
    db.commit()
    return result
