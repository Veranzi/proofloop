"""Case rules: references, membership and status changes (Docs/backend_plan.md, Step 0)."""

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.auth.principal import Principal
from app.db.models import Case, CaseMember, Tenant
from app.enums import CaseStatus, WebhookEvent
from app.services import audit, outbox

# Webhook fired when a case enters a status.
_STATUS_EVENTS = {
    CaseStatus.IN_REVIEW: WebhookEvent.CASE_IN_REVIEW,
    CaseStatus.COMPLETED: WebhookEvent.CASE_COMPLETED,
}


def next_reference(db: Session, tenant_id: str) -> str:
    """Allocate "PL-001", "PL-002"... per tenant. The row lock serialises concurrent creates."""
    row = db.execute(
        update(Tenant)
        .where(Tenant.id == tenant_id)
        .values(next_case_number=Tenant.next_case_number + 1)
        .returning(Tenant.case_prefix, Tenant.next_case_number)
    ).one()
    prefix, after = row
    return f"{prefix}-{after - 1:03d}"


def add_member(db: Session, case_id: str, user_id: str, added_by: str | None) -> None:
    exists = db.scalar(
        select(CaseMember.case_id).where(
            CaseMember.case_id == case_id, CaseMember.user_id == user_id
        )
    )
    if exists is None:
        db.add(CaseMember(case_id=case_id, user_id=user_id, added_by=added_by))


def transition(
    db: Session,
    case: Case,
    new_status: CaseStatus,
    principal: Principal | None = None,
    *,
    reason: str,
    pending_findings: int | None = None,
) -> bool:
    """The only way a case's status changes. Returns False if it was already there.

    ``principal`` is None when the worker makes the change.
    """
    old = CaseStatus(case.status)
    if old == new_status:
        return False
    case.status = new_status
    case.version += 1
    details = {"from": old.value, "to": new_status.value, "reason": reason}
    if principal is not None:
        audit.record(
            db, principal, "case.status_changed", "case", case.id, case_id=case.id, details=details
        )
    else:
        audit.record_system(
            db,
            case.tenant_id,
            "case.status_changed",
            "case",
            case.id,
            case_id=case.id,
            details=details,
        )
    event = _STATUS_EVENTS.get(new_status)
    if event is not None:
        payload: dict[str, object] = {"case_id": case.id}
        if event == WebhookEvent.CASE_IN_REVIEW and pending_findings is not None:
            payload["pending_findings"] = pending_findings
        outbox.emit(db, case.tenant_id, "webhook", event.value, payload)
    return True
