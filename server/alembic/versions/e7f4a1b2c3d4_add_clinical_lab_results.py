"""Add clinical lab results to the sync and restore inventory.

ClinicalLabResult rows were present in the iOS JSON sync payload but were
silently ignored by the server, so they could not return to a replacement
device. This table preserves the app UUID and uses the HealthKit sample UUID as
the natural replay key.

Revision ID: e7f4a1b2c3d4
Revises: d6e8fa0b1c34
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision = "e7f4a1b2c3d4"
down_revision = "d6e8fa0b1c34"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "clinical_lab_results",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("health_kit_sample_uuid", sa.Text(), nullable=False, unique=True),
        sa.Column("effective_date", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("loinc_code", sa.Text(), nullable=False),
        sa.Column("test_name", sa.Text(), nullable=False),
        sa.Column("value", sa.Float(precision=53), nullable=False),
        sa.Column("unit", sa.Text(), nullable=False),
        sa.Column("reference_range_low", sa.Float(precision=53)),
        sa.Column("reference_range_high", sa.Float(precision=53)),
        sa.Column("interpretation", sa.Text()),
        sa.Column("source_name", sa.Text()),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_clinical_lab_results_effective_date",
        "clinical_lab_results",
        [sa.text("effective_date DESC")],
        if_not_exists=True,
    )


def downgrade():
    op.drop_index(
        "idx_clinical_lab_results_effective_date",
        table_name="clinical_lab_results",
        if_exists=True,
    )
    op.drop_table("clinical_lab_results", if_exists=True)
