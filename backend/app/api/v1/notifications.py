"""Notifications (51-53) and profile photo (54-56) for the signed-in person."""

import io
import secrets
from datetime import UTC, datetime
from typing import Literal

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from app.api.v1.me import MeOut, _me
from app.auth.principal import Principal, current_user, require_person
from app.db.models import Case, Notification
from app.db.session import get_db
from app.enums import NotificationKind
from app.errors import ApiError, bad_request, not_found
from app.pagination import after_cursor, clamp_limit, next_cursor_for
from app.services import audit
from app.storage import file_types
from app.storage.backend import Storage, get_storage

router = APIRouter(prefix="/me", tags=["me"])
PERSON = Depends(require_person)

MAX_AVATAR_BYTES = 5 * 1024 * 1024
AVATAR_SIZE = 512
MAX_IMAGE_PIXELS = 40_000_000  # refuse decompression bombs


class NotificationOut(BaseModel):
    id: str
    kind: NotificationKind
    title: str
    body: str
    case_id: str | None
    case_reference: str | None
    link: str
    read: bool
    created_at: datetime


class NotificationPage(BaseModel):
    items: list[NotificationOut]
    next_cursor: str | None
    unread_count: int


def _out(note: Notification, reference: str | None) -> NotificationOut:
    return NotificationOut(
        id=note.id,
        kind=NotificationKind(note.kind),
        title=note.title,
        body=note.body,
        case_id=note.case_id,
        case_reference=reference,
        link=note.link,
        read=note.read_at is not None,
        created_at=note.created_at,
    )


def _mine(principal: Principal) -> tuple[str, str]:
    return current_user(principal).id, principal.tenant_id


@router.get("/notifications", response_model=NotificationPage)
def list_notifications(
    unread_only: bool = False,
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = PERSON,
    db: Session = Depends(get_db),
) -> NotificationPage:
    """51: newest first, with the unread count for the bell."""
    user_id, tenant_id = _mine(principal)
    mine = (Notification.user_id == user_id, Notification.tenant_id == tenant_id)
    size = clamp_limit(limit)
    query = (
        select(Notification, Case.reference)
        .outerjoin(Case, Case.id == Notification.case_id)
        .where(*mine)
    )
    if unread_only:
        query = query.where(Notification.read_at.is_(None))
    rows = db.execute(
        after_cursor(
            query.order_by(Notification.created_at.desc(), Notification.id.desc()).limit(size + 1),
            Notification.created_at,
            Notification.id,
            cursor,
        )
    ).all()
    unread = db.scalar(
        select(func.count()).select_from(Notification).where(*mine, Notification.read_at.is_(None))
    )
    return NotificationPage(
        items=[_out(n, ref) for n, ref in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
        unread_count=int(unread or 0),
    )


@router.post("/notifications/{notification_id}/read", response_model=NotificationOut)
def mark_read(
    notification_id: str, principal: Principal = PERSON, db: Session = Depends(get_db)
) -> NotificationOut:
    """52"""
    user_id, tenant_id = _mine(principal)
    note = db.get(Notification, notification_id)
    if note is None or note.user_id != user_id or note.tenant_id != tenant_id:
        raise not_found("Notification")
    if note.read_at is None:
        note.read_at = datetime.now(UTC)
        db.commit()
    reference = (
        db.scalar(select(Case.reference).where(Case.id == note.case_id)) if note.case_id else None
    )
    return _out(note, reference)


@router.post("/notifications/read-all")
def mark_all_read(principal: Principal = PERSON, db: Session = Depends(get_db)) -> dict[str, int]:
    """53"""
    user_id, tenant_id = _mine(principal)
    updated = db.execute(
        update(Notification)
        .where(
            Notification.user_id == user_id,
            Notification.tenant_id == tenant_id,
            Notification.read_at.is_(None),
        )
        .values(read_at=datetime.now(UTC))
    ).rowcount
    db.commit()
    return {"updated": int(updated or 0)}


# Profile photo -----------------------------------------------------------------


class AvatarUploadIn(BaseModel):
    content_type: Literal["image/png", "image/jpeg"]
    size_bytes: int = Field(ge=1)


class AvatarUploadOut(BaseModel):
    upload_url: str
    method: str
    headers: dict[str, str]
    expires_at: datetime


def _upload_key(user_id: str) -> str:
    return f"users/{user_id}/avatar-upload"


@router.post("/avatar/upload-url", response_model=AvatarUploadOut, status_code=201)
def avatar_upload_url(
    body: AvatarUploadIn, principal: Principal = PERSON, storage: Storage = Depends(get_storage)
) -> AvatarUploadOut:
    """54: then PUT the image and call complete (55)."""
    if body.size_bytes > MAX_AVATAR_BYTES:
        raise bad_request("Photos must be 5 MB or smaller.", "size_bytes", "file_too_large")
    user = current_user(principal)
    signed = storage.upload_request(_upload_key(user.id), body.content_type, MAX_AVATAR_BYTES)
    return AvatarUploadOut(
        upload_url=signed.url,
        method=signed.method,
        headers=signed.headers,
        expires_at=signed.expires_at,
    )


def _reencode(data: bytes) -> bytes:
    """Check it's a real PNG or JPEG, then re-encode: drops metadata such as GPS location."""
    from PIL import Image, ImageOps

    if file_types.detect(data) not in ("image/png", "image/jpeg"):
        raise bad_request("Use a PNG or JPEG image.", code="unsupported_file")
    Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
    try:
        with Image.open(io.BytesIO(data)) as source:
            # Keep phone photos the right way up, then drop everything but the pixels.
            upright = ImageOps.exif_transpose(source) or source
            photo = upright.convert("RGB")
            photo.thumbnail((AVATAR_SIZE, AVATAR_SIZE))
            out = io.BytesIO()
            photo.save(out, format="JPEG", quality=85, optimize=True)  # no EXIF written
            return out.getvalue()
    except (Image.DecompressionBombError, OSError, ValueError) as exc:
        raise bad_request("This image couldn't be read.", code="unsupported_file") from exc


@router.post("/avatar/complete", response_model=MeOut)
def avatar_complete(
    principal: Principal = PERSON,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
) -> MeOut:
    """55"""
    user = current_user(principal)
    key = _upload_key(user.id)
    info = storage.stat(key)
    if info is None:
        raise ApiError(409, "upload_incomplete", "The photo hasn't finished uploading.")
    if info.size > MAX_AVATAR_BYTES:
        storage.delete(key)
        raise bad_request("Photos must be 5 MB or smaller.", code="file_too_large")
    try:
        jpeg = _reencode(storage.read(key))
    finally:
        storage.delete(key)
    new_key = f"users/{user.id}/avatar-{secrets.token_hex(8)}.jpg"
    storage.write(new_key, jpeg, "image/jpeg")
    old_key, user.avatar_key = user.avatar_key, new_key
    audit.record(db, principal, "user.avatar_changed", "user", user.id)
    db.commit()
    if old_key:
        storage.delete(old_key)
    return _me(principal, storage)


@router.delete("/avatar", status_code=204)
def avatar_delete(
    principal: Principal = PERSON,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
) -> Response:
    """56"""
    user = current_user(principal)
    if user.avatar_key:
        old_key, user.avatar_key = user.avatar_key, None
        audit.record(db, principal, "user.avatar_removed", "user", user.id)
        db.commit()
        storage.delete(old_key)
    return Response(status_code=204)
