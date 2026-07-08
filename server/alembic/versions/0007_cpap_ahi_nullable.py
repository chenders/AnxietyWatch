"""Make cpap_sessions.ahi nullable.

EDF-only imports (edf_parser.upsert_cpap_leak) previously inserted
ahi = 0.0 as an "unknown AHI" sentinel because the column was NOT NULL.
That made a night whose AHI was never measured indistinguishable from a
genuinely perfect zero-event night in every downstream consumer — AHI
trends, correlations, and the Claude analysis prompt all read a
fabricated clinical value. NULL is the honest representation: consumers
skip it instead of averaging in a fake zero.

Existing 0.0 rows are NOT backfilled to NULL here: a real AHI of 0.0 is
clinically possible and rows written by the CSV/cloud importers carry
measured zeros. Only rows created by future EDF-only imports will be
NULL.

Revision ID: 0007
Revises: 0006
Create Date: 2026-07-08
"""
from alembic import op


revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("ALTER TABLE cpap_sessions ALTER COLUMN ahi DROP NOT NULL")


def downgrade():
    # Lossy: restores the pre-migration 0.0 sentinel for unknown-AHI rows
    # so the NOT NULL constraint can be re-added.
    op.execute("UPDATE cpap_sessions SET ahi = 0.0 WHERE ahi IS NULL")
    op.execute("ALTER TABLE cpap_sessions ALTER COLUMN ahi SET NOT NULL")
