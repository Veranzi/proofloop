"""API keys: endpoints 34-36 (Docs/Integrations_API_Contract.md §1)."""

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import api_keys
from app.auth.permissions import Permission
from app.auth.principal import Principal, require
from app.db.models import ApiKey, User
from app.db.session import get_db
from app.enums import ApiKeyScope
from app.errors import not_found
from app.ids import new_id
from app.pagination import Page, after_cursor, clamp_limit, next_cursor_for
from app.services import audit

router = APIRouter(prefix="/admin/api-keys", tags=["integrations"])


class CreatedBy(BaseModel):
    uid: str
    name: str


class ApiKeyOut(BaseModel):
    id: str
    name: str
    prefix: str
    scopes: list[ApiKeyScope]
    created_at: datetime
    created_by: CreatedBy | None
    last_used_at: datetime | None
    revoked: bool


class ApiKeyCreated(ApiKeyOut):
    secret: str  # returned only here, once


class ApiKeyIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    scopes: list[ApiKeyScope] = Field(min_length=1)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name can't be blank")
        return v.strip()


def _out(key: ApiKey, creator: User | None) -> ApiKeyOut:
    return ApiKeyOut(
        id=key.id,
        name=key.name,
        prefix=key.prefix,
        scopes=[ApiKeyScope(s) for s in key.scopes],
        created_at=key.created_at,
        created_by=CreatedBy(uid=creator.id, name=creator.name) if creator else None,
        last_used_at=key.last_used_at,
        revoked=key.revoked_at is not None,
    )


@router.get("", response_model=Page[ApiKeyOut])
def list_keys(
    cursor: str | None = None,
    limit: int | None = None,
    principal: Principal = Depends(require(Permission.ADMIN)),
    db: Session = Depends(get_db),
) -> Page[ApiKeyOut]:
    """34"""
    size = clamp_limit(limit)
    query = after_cursor(
        select(ApiKey, User)
        .outerjoin(User, User.id == ApiKey.created_by)
        .where(ApiKey.tenant_id == principal.tenant_id)
        .order_by(ApiKey.created_at.desc(), ApiKey.id.desc())
        .limit(size + 1),
        ApiKey.created_at,
        ApiKey.id,
        cursor,
    )
    rows = db.execute(query).all()
    return Page[ApiKeyOut](
        items=[_out(key, creator) for key, creator in rows[:size]],
        next_cursor=next_cursor_for(rows, size, lambda r: (r[0].created_at, r[0].id)),
    )


@router.post("", response_model=ApiKeyCreated, status_code=201)
def create_key(
    body: ApiKeyIn,
    principal: Principal = Depends(require(Permission.ADMIN)),
    db: Session = Depends(get_db),
) -> ApiKeyCreated:
    """35: the full key is in ``secret`` and is never returned again."""
    secret = api_keys.generate_key()
    key = ApiKey(
        id=new_id("key"),
        tenant_id=principal.tenant_id,
        name=body.name,
        prefix=api_keys.display_prefix(secret),
        key_hash=api_keys.hash_key(secret),
        scopes=sorted({s.value for s in body.scopes}),
        created_by=principal.user_id,
    )
    db.add(key)
    db.flush()
    audit.record(
        db,
        principal,
        "api_key.created",
        "api_key",
        key.id,
        details={"name": key.name, "scopes": key.scopes},
    )
    db.commit()
    db.refresh(key)
    return ApiKeyCreated(**_out(key, principal.user).model_dump(), secret=secret)


@router.delete("/{key_id}", status_code=204)
def revoke_key(
    key_id: str,
    principal: Principal = Depends(require(Permission.ADMIN)),
    db: Session = Depends(get_db),
) -> Response:
    """36: permanent. The row stays so the audit trail stays readable."""
    key = db.get(ApiKey, key_id)
    if key is None or key.tenant_id != principal.tenant_id:
        raise not_found("API key")
    if key.revoked_at is None:
        key.revoked_at = datetime.now(UTC)
        audit.record(db, principal, "api_key.revoked", "api_key", key.id)
        db.commit()
    return Response(status_code=204)
