"""Evidence upload (Docs/backend_plan.md, Step 6).

1. ``create_upload``: check the request, create the row, return a signed URL
   for an object key the server chose.
2. The client PUTs the bytes straight to storage.
3. ``complete_upload``: check what actually arrived (size, real type, pages),
   compute the checksum, then queue processing in the same transaction.
"""

import contextlib
import hashlib
import io
from datetime import UTC, datetime

from pypdf import PdfReader
from pypdf.errors import PdfReadError
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.auth.principal import Principal
from app.config import MAX_FILE_BYTES, MAX_FILES_PER_BATCH, MAX_PAGES
from app.db.models import Case, EvidenceFile, ProcessingJob
from app.enums import CaseStatus, EvidenceSource, EvidenceStatus
from app.errors import ApiError, bad_request, conflict
from app.ids import new_id
from app.services import audit, outbox
from app.services import cases as case_service
from app.storage import file_types
from app.storage.backend import SignedRequest, Storage

EVIDENCE_KINDS = ("documents", "images", "other")
# Statuses a failed file can be retried from. Validation failures are final.
RETRYABLE = {EvidenceStatus.FAILED_RETRYABLE, EvidenceStatus.FAILED_TERMINAL}
NOT_RETRYABLE_ERRORS = {"file_too_large", "unsupported_file", "too_many_pages", "encrypted_pdf"}


class UploadRejected(ApiError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(400, code, message)


def create_upload(
    db: Session,
    principal: Principal,
    case: Case,
    *,
    file_name: str,
    size_bytes: int,
    content_type: str,
    evidence_types: list[str],
    storage: Storage,
) -> tuple[EvidenceFile, SignedRequest]:
    extension = file_types.extension_of(file_name)
    file_type = file_types.FILE_TYPES.get(extension)
    if file_type is None:
        allowed = ", ".join(sorted({e.lstrip(".").upper() for e in file_types.FILE_TYPES}))
        raise bad_request(
            f"This file type isn't supported. Use {allowed}.",
            field="file_name",
            code="unsupported_file",
        )
    if content_type.split(";")[0].strip().lower() not in file_type.declared:
        raise bad_request(
            "The file type doesn't match its extension.",
            field="content_type",
            code="unsupported_file",
        )
    if size_bytes > MAX_FILE_BYTES:
        raise bad_request(
            "Files must be 25 MB or smaller.", field="size_bytes", code="file_too_large"
        )
    in_flight = db.scalar(
        select(func.count())
        .select_from(EvidenceFile)
        .where(EvidenceFile.case_id == case.id, EvidenceFile.status == EvidenceStatus.UPLOADING)
    )
    if (in_flight or 0) >= MAX_FILES_PER_BATCH:
        raise conflict(f"Finish the current uploads first (at most {MAX_FILES_PER_BATCH} at once).")

    evidence_id = new_id("evd")
    evidence = EvidenceFile(
        id=evidence_id,
        tenant_id=case.tenant_id,
        case_id=case.id,
        object_key=f"tenants/{case.tenant_id}/cases/{case.id}/evidence/{evidence_id}{extension}",
        original_filename=file_name,
        declared_mime=file_type.mime,
        byte_size=size_bytes,
        evidence_types=sorted(set(evidence_types)) or [file_type.kind],
        status=EvidenceStatus.UPLOADING,
        uploaded_by=principal.user_id,
    )
    db.add(evidence)
    db.flush()
    return evidence, storage.upload_request(evidence.object_key, file_type.mime, MAX_FILE_BYTES)


def _inspect(evidence: EvidenceFile, data: bytes) -> tuple[str, int | None]:
    """Return (detected type, page count) or raise UploadRejected."""
    if len(data) > MAX_FILE_BYTES:
        raise UploadRejected("file_too_large", "Files must be 25 MB or smaller.")
    extension = file_types.extension_of(evidence.original_filename)
    detected = file_types.detect(data)
    if detected is None or not file_types.matches(extension, detected):
        raise UploadRejected("unsupported_file", "The file's content doesn't match its type.")
    pages: int | None = 1 if detected.startswith("image/") else None
    if detected == "application/pdf":
        try:
            reader = PdfReader(io.BytesIO(data))
            if reader.is_encrypted:
                raise UploadRejected("encrypted_pdf", "Password-protected PDFs can't be read.")
            pages = len(reader.pages)
        except (PdfReadError, ValueError, KeyError) as exc:
            raise UploadRejected("unsupported_file", "This PDF couldn't be read.") from exc
        if pages > MAX_PAGES:
            raise UploadRejected("too_many_pages", f"PDFs can have at most {MAX_PAGES} pages.")
    file_type = file_types.FILE_TYPES[extension]
    return file_type.mime, pages


def complete_upload(
    db: Session, principal: Principal, case: Case, evidence: EvidenceFile, storage: Storage
) -> EvidenceFile:
    if evidence.status != EvidenceStatus.UPLOADING:
        return evidence  # already completed: calling again is harmless
    info = storage.stat(evidence.object_key)
    if info is None:
        raise ApiError(409, "upload_incomplete", "The file hasn't finished uploading.")
    data = storage.read(evidence.object_key)
    _accept(db, principal, case, evidence, data, title=f"Uploaded {evidence.original_filename}")
    return evidence


def _accept(
    db: Session,
    principal: Principal | None,
    case: Case,
    evidence: EvidenceFile,
    data: bytes,
    *,
    title: str,
) -> None:
    """Check what arrived, then queue it in the same transaction. Shared by
    uploads and importers (``principal`` is None for a scheduled import).
    Commits; raises UploadRejected after recording a rejected file."""
    evidence.byte_size = len(data)
    evidence.sha256 = hashlib.sha256(data).hexdigest()
    evidence.uploaded_at = datetime.now(UTC)
    try:
        evidence.detected_mime, evidence.page_count = _inspect(evidence, data)
    except UploadRejected as rejected:
        # Kept, but never processed: it shows as failed with the reason.
        evidence.status = EvidenceStatus.FAILED_TERMINAL
        evidence.error_class = rejected.code
        _audit(
            db,
            principal,
            case,
            "evidence.rejected",
            evidence.id,
            {"reason": rejected.code, "source": evidence.source},
        )
        db.commit()
        raise
    queue_processing(db, evidence, attempt=1)
    if case.status != CaseStatus.AWAITING_EVIDENCE:
        case_service.transition(
            db, case, CaseStatus.AWAITING_EVIDENCE, principal, reason="new evidence"
        )
    details: dict[str, object] = {"title": title, "sha256": evidence.sha256}
    if evidence.source != EvidenceSource.UPLOAD:
        details["source"] = evidence.source
    _audit(db, principal, case, "evidence.uploaded", evidence.id, details)
    db.commit()


def _audit(
    db: Session,
    principal: Principal | None,
    case: Case,
    action: str,
    evidence_id: str,
    details: dict[str, object],
) -> None:
    if principal is None:
        audit.record_system(
            db, case.tenant_id, action, "evidence", evidence_id, case_id=case.id, details=details
        )
    else:
        audit.record(
            db, principal, action, "evidence", evidence_id, case_id=case.id, details=details
        )


def import_file(
    db: Session,
    storage: Storage,
    case: Case,
    *,
    file_name: str,
    data: bytes | None,
    source: EvidenceSource,
    source_ref: str,
    principal: Principal | None = None,
    uploaded_by: str | None = None,
    size: int | None = None,
) -> EvidenceFile | None:
    """Store a file a connector fetched and treat it exactly like a finished
    upload: same types, limits, checksum and queue. Returns None when the
    source already sent this file. Rejected files are kept as failed, like
    uploads; a type that's never accepted raises UploadRejected. Pass
    ``data=None`` with ``size`` for a file too big to fetch."""
    exists = db.scalar(
        select(EvidenceFile.id).where(
            EvidenceFile.tenant_id == case.tenant_id,
            EvidenceFile.source == source,
            EvidenceFile.source_ref == source_ref,
        )
    )
    if exists is not None:
        return None
    extension = file_types.extension_of(file_name)
    file_type = file_types.FILE_TYPES.get(extension)
    if file_type is None:
        raise UploadRejected("unsupported_file", "This file type isn't supported.")
    evidence_id = new_id("evd")
    evidence = EvidenceFile(
        id=evidence_id,
        tenant_id=case.tenant_id,
        case_id=case.id,
        object_key=f"tenants/{case.tenant_id}/cases/{case.id}/evidence/{evidence_id}{extension}",
        original_filename=file_name[:255],
        declared_mime=file_type.mime,
        byte_size=len(data) if data is not None else max(size or 0, 0),
        evidence_types=[file_type.kind],
        status=EvidenceStatus.UPLOADING,
        uploaded_by=uploaded_by or (principal.user_id if principal else None),
        source=source,
        source_ref=source_ref,
    )
    db.add(evidence)
    db.flush()
    if data is None or len(data) > MAX_FILE_BYTES:
        # Recorded as rejected without fetching or keeping the bytes.
        evidence.status = EvidenceStatus.FAILED_TERMINAL
        evidence.error_class = "file_too_large"
        _audit(
            db,
            principal,
            case,
            "evidence.rejected",
            evidence.id,
            {"reason": "file_too_large", "source": source},
        )
        db.commit()
        return evidence
    storage.write(evidence.object_key, data, file_type.mime)
    # A rejection is recorded on the row; the import carries on with the next file.
    with contextlib.suppress(UploadRejected):
        _accept(db, principal, case, evidence, data, title=f"Imported {evidence.original_filename}")
    return evidence


def queue_processing(db: Session, evidence: EvidenceFile, attempt: int) -> ProcessingJob:
    """Mark the file queued and write the job + outbox event in the caller's transaction."""
    job = ProcessingJob(
        id=new_id("job"),
        evidence_id=evidence.id,
        idempotency_key=f"{evidence.id}:process:{attempt}",
    )
    db.add(job)
    evidence.status = EvidenceStatus.QUEUED
    evidence.error_class = None
    db.flush()
    outbox.emit(
        db,
        evidence.tenant_id,
        "processing",
        "evidence.process",
        {"evidence_id": evidence.id, "job_id": job.id},
    )
    return job


def retry(db: Session, principal: Principal, case: Case, evidence: EvidenceFile) -> EvidenceFile:
    if evidence.status not in RETRYABLE:
        raise conflict("Only failed files can be retried.")
    if evidence.error_class in NOT_RETRYABLE_ERRORS:
        raise conflict("This file was rejected. Upload a corrected file instead.")
    attempts = db.scalar(
        select(func.count())
        .select_from(ProcessingJob)
        .where(ProcessingJob.evidence_id == evidence.id)
    )
    queue_processing(db, evidence, attempt=(attempts or 0) + 1)
    if case.status != CaseStatus.AWAITING_EVIDENCE:
        case_service.transition(
            db, case, CaseStatus.AWAITING_EVIDENCE, principal, reason="evidence retried"
        )
    audit.record(db, principal, "evidence.retried", "evidence", evidence.id, case_id=case.id)
    db.commit()
    return evidence
