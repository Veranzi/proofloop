"""connector importers

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-17 09:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "evidence_files",
        sa.Column("source", sa.String(length=20), server_default="upload", nullable=False),
    )
    op.add_column("evidence_files", sa.Column("source_ref", sa.String(length=300), nullable=True))
    op.create_check_constraint(
        op.f("ck_evidence_files_source_valid"),
        "evidence_files",
        "source IN ('upload', 'email_inbox', 'google_drive', 'sharepoint', 'odoo')",
    )
    op.create_index(
        "uq_evidence_files_source_ref",
        "evidence_files",
        ["tenant_id", "source", "source_ref"],
        unique=True,
        postgresql_where="source_ref IS NOT NULL",
    )
    op.add_column("connectors", sa.Column("secret", sa.Text(), nullable=True))
    op.add_column(
        "connectors",
        sa.Column(
            "state",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="{}",
            nullable=False,
        ),
    )
    op.add_column("connectors", sa.Column("connected_by", sa.String(length=40), nullable=True))
    op.add_column(
        "connectors", sa.Column("last_synced_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_foreign_key(
        op.f("fk_connectors_connected_by_users"),
        "connectors",
        "users",
        ["connected_by"],
        ["id"],
        ondelete="RESTRICT",
    )


def downgrade() -> None:
    op.drop_constraint(op.f("fk_connectors_connected_by_users"), "connectors", type_="foreignkey")
    op.drop_column("connectors", "last_synced_at")
    op.drop_column("connectors", "connected_by")
    op.drop_column("connectors", "state")
    op.drop_column("connectors", "secret")
    op.drop_index("uq_evidence_files_source_ref", table_name="evidence_files")
    op.drop_constraint(op.f("ck_evidence_files_source_valid"), "evidence_files", type_="check")
    op.drop_column("evidence_files", "source_ref")
    op.drop_column("evidence_files", "source")
