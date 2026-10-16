"""Write audit events. Callers commit them in the same transaction as the change."""

from typing import Any

from sqlalchemy.orm import Session

from app.auth.principal import Principal
from app.context import request_id_var
from app.db.models import AuditEvent
from app.ids import new_id


def record(
    db: Session,
    principal: Principal,
    action: str,
    target_type: str,
    target_id: str,
    *,
    case_id: str | None = None,
    details: dict[str, Any] | None = None,
) -> AuditEvent:
    event = AuditEvent(
        id=new_id("aud"),
        tenant_id=principal.tenant_id,
        actor_user_id=principal.user_id,
        actor_api_key_id=principal.api_key_id,
        action=action,
        target_type=target_type,
        target_id=target_id,
        case_id=case_id,
        request_id=request_id_var.get(),
        details=details or {},
    )
    db.add(event)
    return event
