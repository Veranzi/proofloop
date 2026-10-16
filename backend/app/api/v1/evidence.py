"""Evidence: endpoints 7, 8, 9, 10 and 11."""

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.permissions import Permission
from app.auth.principal import Principal, load_case, require
from app.db.models import Case, EvidenceFile
from app.db.session import get_db
from app.enums import EvidenceStatus
from app.errors import not_found
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import evidence as evidence_service
from app.storage.backend import Storage, get_storage

router = APIRouter(prefix="/cases/{case_id}/evidence", tags=["evidence"])

EvidenceKind = Literal["documents", "images", "other"]


class UploadUrlIn(BaseModel):
    file_name: str = Field(min_length=1, max_length=255)
    size_bytes: int = Field(ge=1)
    content_type: str = Field(min_length=1, max_length=120)
    evidence_types: list[EvidenceKind] = Field(min_length=1)


class UploadUrlOut(BaseModel):
    evidence_id: str
    upload_url: str
    method: str
    headers: dict[str, str]  # send these with the PUT, or storage rejects it
    expires_at: datetime


class EvidenceOut(BaseModel):
    id: str
    case_id: str
    file_name: str
    content_type: str
    size_bytes: int
    page_count: int | None
    evidence_types: list[str]
    status: EvidenceStatus
    error_class: str | None
    sha256: str | None
    uploaded_at: datetime | None
    created_at: datetime


class ViewUrlOut(BaseModel):
    url: str
    expires_at: datetime


def _out(evidence: EvidenceFile) -> EvidenceOut:
    return EvidenceOut(
        id=evidence.id,
        case_id=evidence.case_id,
        file_name=evidence.original_filename,
        content_type=evidence.detected_mime or evidence.declared_mime,
        size_bytes=evidence.byte_size,
        page_count=evidence.page_count,
        evidence_types=evidence.evidence_types,
        status=EvidenceStatus(evidence.status),
        error_class=evidence.error_class,
        sha256=evidence.sha256,
        uploaded_at=evidence.uploaded_at,
        created_at=evidence.created_at,
    )


def _load_evidence(db: Session, case: Case, evidence_id: str) -> EvidenceFile:
    evidence = db.get(EvidenceFile, evidence_id)
    if evidence is None or evidence.case_id != case.id:
        raise not_found("Evidence")
    return evidence


@router.post("/upload-url", response_model=UploadUrlOut, status_code=201)
def create_upload_url(
    case_id: str,
    body: UploadUrlIn,
    principal: Principal = Depends(require(Permission.UPLOAD_EVIDENCE)),
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
) -> UploadUrlOut:
    """7: returns a short-lived signed URL. Then PUT the file, then call ``complete``."""
    case = load_case(db, principal, case_id)
    evidence, signed = evidence_service.create_upload(
        db,
        principal,
        case,
        file_name=body.file_name.strip(),
        size_bytes=body.size_bytes,
        content_type=body.content_type,
        evidence_types=list(body.evidence_types),
        storage=storage,
    )
    db.commit()
    return UploadUrlOut(
        evidence_id=evidence.id,
        upload_url=signed.url,
        method=signed.method,
        headers=signed.headers,
        expires_at=signed.expires_at,
    )


@router.post("/{evidence_id}/complete", response_model=EvidenceOut)
def complete_upload(
    case_id: str,
    evidence_id: str,
    principal: Principal = Depends(require(Permission.UPLOAD_EVIDENCE)),
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
) -> EvidenceOut:
    """8: verify the uploaded file on the server and queue it for processing."""
    case = load_case(db, principal, case_id)
    evidence = _load_evidence(db, case, evidence_id)
    return _out(evidence_service.complete_upload(db, principal, case, evidence, storage))


@router.get("", response_model=Page[EvidenceOut])
def list_evidence(
    case_id: str,
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
) -> Page[EvidenceOut]:
    """9: the case's files and their processing status, newest first."""
    case = load_case(db, principal, case_id)
    size = clamp_limit(limit)
    query = after_cursor(
        select(EvidenceFile)
        .where(EvidenceFile.case_id == case.id)
        .order_by(EvidenceFile.created_at.desc(), EvidenceFile.id.desc())
        .limit(size + 1),
        EvidenceFile.created_at,
        EvidenceFile.id,
        cursor,
    )
    rows = db.scalars(query).all()
    return Page[EvidenceOut](
        items=[_out(e) for e in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda e: (e.created_at, e.id)),
    )


@router.post("/{evidence_id}/retry", response_model=EvidenceOut)
def retry_evidence(
    case_id: str,
    evidence_id: str,
    principal: Principal = Depends(require(Permission.UPLOAD_EVIDENCE)),
    db: Session = Depends(get_db),
) -> EvidenceOut:
    """10: queue a failed file again. Rejected files (wrong type, too big) can't be retried."""
    case = load_case(db, principal, case_id)
    evidence = _load_evidence(db, case, evidence_id)
    return _out(evidence_service.retry(db, principal, case, evidence))


@router.get("/{evidence_id}/view-url", response_model=ViewUrlOut)
def view_url(
    case_id: str,
    evidence_id: str,
    principal: Principal = Depends(require(Permission.VIEW_CASES)),
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
) -> ViewUrlOut:
    """11: a short-lived link to the original file. ``?page=`` is for the viewer only."""
    case = load_case(db, principal, case_id)
    evidence = _load_evidence(db, case, evidence_id)
    if evidence.status == EvidenceStatus.UPLOADING:
        raise not_found("Evidence")
    signed = storage.view_url(
        evidence.object_key,
        evidence.original_filename,
        evidence.detected_mime or evidence.declared_mime,
    )
    return ViewUrlOut(url=signed.url, expires_at=signed.expires_at)
