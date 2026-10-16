"""Claims, findings and review decisions: endpoints 13, 14 and 15.

Only a signed-in reviewer or admin decides. AI output is shown with its
source; the decision is always a person's (Docs/backend_plan.md, rule 1).
"""

from collections.abc import Sequence
from datetime import datetime
from typing import Any, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, Query
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.v1.cases import PersonRef
from app.auth.permissions import Permission
from app.auth.principal import Principal, current_user, load_case, require
from app.context import request_id_var
from app.db.models import EvidenceFile, ExtractedClaim, Finding, ReviewAction, User
from app.db.session import get_db
from app.enums import GroundingStatus, ReviewDecision, Severity, WebhookEvent
from app.errors import not_found
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit, outbox
from app.services import cases as case_service
from app.worker.queue import Queue, get_queue

router = APIRouter(prefix="/cases/{case_id}", tags=["review"])


class ClaimOut(BaseModel):
    id: str
    evidence_id: str
    file_name: str
    field: str
    value: str | None
    unit: str | None
    page: int | None
    quote: str | None
    grounding: GroundingStatus
    bbox: dict[str, float] | None
    model: str
    created_at: datetime


class Correction(BaseModel):
    field: str = Field(min_length=1, max_length=80)
    previous: str = Field(max_length=500)
    new: str = Field(max_length=500)


class ReviewOut(BaseModel):
    status: ReviewDecision
    by: PersonRef | None
    at: datetime | None
    note: str
    correction: Correction | None


class FindingOut(BaseModel):
    id: str
    rule_id: str
    rule_version: int
    type: str
    severity: Severity
    expected: dict[str, Any] | None
    observed: dict[str, Any] | None
    difference: dict[str, Any] | None
    explanation: str
    explanation_source: Literal["template", "machine_generated"]
    review: ReviewOut
    evidence: list[ClaimOut]
    created_at: datetime


class DecisionIn(BaseModel):
    decision: ReviewDecision
    note: str = Field(default="", max_length=2000)
    correction: Correction | None = None

    @model_validator(mode="after")
    def _note_needed(self) -> "DecisionIn":
        self.note = self.note.strip()
        if self.decision != ReviewDecision.APPROVE and not self.note:
            raise ValueError("Add a note explaining why (required for reject and pending).")
        return self


def _claim_out(claim: ExtractedClaim, file_name: str) -> ClaimOut:
    return ClaimOut(
        id=claim.id,
        evidence_id=claim.evidence_id,
        file_name=file_name,
        field=claim.field_name,
        value=claim.normalized_value if claim.normalized_value is not None else claim.raw_value,
        unit=claim.unit,
        page=claim.page_index,
        quote=claim.source_quote,
        grounding=GroundingStatus(claim.grounding),
        bbox=claim.bbox,
        model=claim.model,
        created_at=claim.created_at,
    )


def _findings_out(db: Session, findings: Sequence[Finding]) -> list[FindingOut]:
    """Batch-load the cited claims and the latest decision for each finding."""
    claim_ids = {cid for f in findings for cid in f.input_claim_ids}
    claims = {
        claim.id: _claim_out(claim, name)
        for claim, name in db.execute(
            select(ExtractedClaim, EvidenceFile.original_filename)
            .join(EvidenceFile, EvidenceFile.id == ExtractedClaim.evidence_id)
            .where(ExtractedClaim.id.in_(claim_ids))
        ).all()
    }
    latest: dict[str, tuple[ReviewAction, User]] = {}
    for action, user in db.execute(
        select(ReviewAction, User)
        .join(User, User.id == ReviewAction.actor_user_id)
        .where(ReviewAction.finding_id.in_([f.id for f in findings]))
        .order_by(ReviewAction.created_at.desc(), ReviewAction.id.desc())
    ).all():
        latest.setdefault(action.finding_id, (action, user))

    out = []
    for f in findings:
        action, user = latest.get(f.id, (None, None))
        out.append(
            FindingOut(
                id=f.id,
                rule_id=f.rule_id,
                rule_version=f.rule_version,
                type=f.finding_type,
                severity=Severity(f.severity),
                expected=f.expected,
                observed=f.observed,
                difference=f.difference,
                explanation=f.explanation,
                explanation_source="machine_generated"
                if f.explanation_source == "machine_generated"
                else "template",
                review=ReviewOut(
                    status=ReviewDecision(f.review_status),
                    by=PersonRef(uid=user.id, name=user.name) if user else None,
                    at=action.created_at if action else None,
                    note=action.note if action else "",
                    correction=Correction(**action.correction)
                    if action and action.correction
                    else None,
                ),
                evidence=[claims[c] for c in f.input_claim_ids if c in claims],
                created_at=f.created_at,
            )
        )
    return out


@router.get("/claims", response_model=Page[ClaimOut])
def list_claims(
    case_id: str,
    evidence_id: str | None = Query(default=None, max_length=40),
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> Page[ClaimOut]:
    """13: values extracted from the case's evidence, with their source."""
    case = load_case(db, principal, case_id)
    size = clamp_limit(limit)
    query = (
        select(ExtractedClaim, EvidenceFile.original_filename)
        .join(EvidenceFile, EvidenceFile.id == ExtractedClaim.evidence_id)
        .where(ExtractedClaim.case_id == case.id)
    )
    if evidence_id:
        query = query.where(ExtractedClaim.evidence_id == evidence_id)
    rows = db.execute(
        after_cursor(
            query.order_by(ExtractedClaim.created_at.desc(), ExtractedClaim.id.desc()).limit(
                size + 1
            ),
            ExtractedClaim.created_at,
            ExtractedClaim.id,
            cursor,
        )
    ).all()
    return Page[ClaimOut](
        items=[_claim_out(c, name) for c, name in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )


@router.get("/findings", response_model=Page[FindingOut])
def list_findings(
    case_id: str,
    review_status: ReviewDecision | None = None,
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> Page[FindingOut]:
    """14: rule-generated findings with their cited evidence and review state."""
    case = load_case(db, principal, case_id)
    size = clamp_limit(limit)
    query = select(Finding).where(Finding.case_id == case.id)
    if review_status:
        query = query.where(Finding.review_status == review_status)
    rows = db.scalars(
        after_cursor(
            query.order_by(Finding.created_at.desc(), Finding.id.desc()).limit(size + 1),
            Finding.created_at,
            Finding.id,
            cursor,
        )
    ).all()
    return Page[FindingOut](
        items=_findings_out(db, rows[:size]),
        next_cursor=next_cursor_for(rows, size, lambda f: (f.created_at, f.id)),
    )


_DECISION_TITLES = {
    ReviewDecision.APPROVE: "Approved",
    ReviewDecision.REJECT: "Rejected",
    ReviewDecision.PENDING: "Set to pending",
}


@router.post("/findings/{finding_id}/decision", response_model=FindingOut)
def decide(
    case_id: str,
    finding_id: str,
    body: DecisionIn,
    background: BackgroundTasks,
    principal: Principal = Depends(require(Permission.DECIDE)),
    db: Session = Depends(get_db),
    queue: Queue = Depends(get_queue),
) -> FindingOut:
    """15: a person's decision. Kept forever in review_actions and the audit trail."""
    case = load_case(db, principal, case_id)
    finding = db.get(Finding, finding_id)
    if finding is None or finding.case_id != case.id:
        raise not_found("Finding")
    user = current_user(principal)
    action = ReviewAction(
        id=new_id("rva"),
        tenant_id=case.tenant_id,
        case_id=case.id,
        finding_id=finding.id,
        actor_user_id=user.id,
        decision=body.decision,
        note=body.note,
        correction=body.correction.model_dump() if body.correction else None,
        request_id=request_id_var.get(),
    )
    db.add(action)
    previous = finding.review_status
    finding.review_status = body.decision
    audit.record(
        db,
        principal,
        "finding.decided",
        "finding",
        finding.id,
        case_id=case.id,
        details={
            "title": f"{_DECISION_TITLES[body.decision]} a finding in {case.reference}",
            "decision": body.decision,
            "previous": previous,
            "note": body.note,
            "correction": action.correction,
        },
    )
    outbox.emit(
        db,
        case.tenant_id,
        "webhook",
        WebhookEvent.FINDING_DECIDED.value,
        {
            "case_id": case.id,
            "finding_id": finding.id,
            "decision": body.decision,
            "actor_uid": user.id,
        },
    )
    db.flush()
    case_service.refresh_after_review(db, case, principal)
    db.commit()
    background.add_task(queue.kick)  # sends finding.decided and any case webhooks
    return _findings_out(db, [finding])[0]
