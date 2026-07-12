"""Remove prescription supply-tracking columns.

Supply/expiration tracking is removed from the app (no run-out math, no
supply alerts); prescriptions are simple descriptive records. Drops the four
columns that only existed to feed that math. No rows are deleted.

Revision ID: 0012
Revises: 0011
"""
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None

SUPPLY_COLUMNS = (
    "quantity", "refills_remaining", "estimated_run_out_date", "daily_dose_count",
)


def upgrade():
    for col in SUPPLY_COLUMNS:
        op.execute(f"ALTER TABLE prescriptions DROP COLUMN IF EXISTS {col}")


def downgrade():
    # Data is not restorable; recreate the columns to baseline shape so old
    # code can run. quantity was NOT NULL with no default in the baseline —
    # backfill existing rows with 0 via a temporary default, then drop the
    # default to match the baseline definition exactly.
    op.execute("""
        ALTER TABLE prescriptions
            ADD COLUMN IF NOT EXISTS quantity INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS refills_remaining INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS estimated_run_out_date TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS daily_dose_count DOUBLE PRECISION
    """)
    op.execute("ALTER TABLE prescriptions ALTER COLUMN quantity DROP DEFAULT")
