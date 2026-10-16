import pytest
from alembic import command
from sqlalchemy import Engine, inspect, text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.orm import Session

from app.db.base import Base
from app.db.models import AuditEvent, Case, Tenant
from app.enums import CaseStatus
from app.ids import new_id
from tests.conftest import TEST_URL, alembic_config


def _tenant(db: Session) -> Tenant:
    tenant = Tenant(id=new_id("ten"), name="Acme")
    db.add(tenant)
    db.flush()
    return tenant


def test_migration_creates_every_model_table(engine: Engine) -> None:
    tables = set(inspect(engine).get_table_names())
    assert set(Base.metadata.tables) <= tables


def test_case_defaults_and_status_check(db: Session) -> None:
    tenant = _tenant(db)
    case = Case(id=new_id("case"), tenant_id=tenant.id, reference="PL-001", title="Fraud")
    db.add(case)
    db.flush()
    db.refresh(case)
    assert case.status == CaseStatus.AWAITING_EVIDENCE
    assert case.priority == "medium"

    with pytest.raises(IntegrityError), db.begin_nested():
        db.execute(text("UPDATE cases SET status = 'reviewed' WHERE id = :id"), {"id": case.id})


def test_case_reference_unique_per_tenant(db: Session) -> None:
    tenant = _tenant(db)
    db.add(Case(id=new_id("case"), tenant_id=tenant.id, reference="PL-001", title="A"))
    db.flush()
    with pytest.raises(IntegrityError), db.begin_nested():
        db.add(Case(id=new_id("case"), tenant_id=tenant.id, reference="PL-001", title="B"))
        db.flush()


def test_audit_events_are_append_only(db: Session) -> None:
    tenant = _tenant(db)
    event = AuditEvent(
        id=new_id("aud"),
        tenant_id=tenant.id,
        action="case.created",
        target_type="case",
        target_id="case_x",
        request_id="req_1",
    )
    db.add(event)
    db.flush()
    for sql in ("UPDATE audit_events SET action = 'x'", "DELETE FROM audit_events"):
        with pytest.raises(DBAPIError, match="append-only"), db.begin_nested():
            db.execute(text(sql))


def test_migration_downgrades_cleanly(engine: Engine) -> None:
    cfg = alembic_config(TEST_URL)
    command.downgrade(cfg, "base")
    try:
        assert "cases" not in inspect(engine).get_table_names()
    finally:
        command.upgrade(cfg, "head")
    assert "cases" in inspect(engine).get_table_names()
