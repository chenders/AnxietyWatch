"""Remove pharmacy-import columns and all Walgreens/CapRx settings keys.

Prescription IMPORT (Walgreens scrape, CapRx claims) is removed; medications
are entered manually. Rows are kept — dropping import_source makes every
surviving prescription an ordinary manual record. From settings, every
`walgreens_%`/`caprx_%` key is deleted: encrypted credentials plus the
importers' sync-state leftovers (last-sync cursors, status, session keys),
all of which are dead once the importers are gone. No prescription rows are
deleted.

Revision ID: 0011
Revises: 0010
"""
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None

IMPORT_COLUMNS = (
    "prescriber_name", "ndc_code", "rx_status", "last_fill_date",
    "import_source", "walgreens_rx_id", "directions", "days_supply",
    "patient_pay", "plan_pay", "dosage_form", "drug_type",
)


def upgrade():
    op.execute(
        "DELETE FROM settings WHERE key LIKE 'walgreens\\_%' OR key LIKE 'caprx\\_%'"
    )
    for col in IMPORT_COLUMNS:
        op.execute(f"ALTER TABLE prescriptions DROP COLUMN IF EXISTS {col}")


def downgrade():
    # Data is not restorable; recreate the columns empty so old code can run.
    # Types/defaults/nullability mirror the baseline (0001_baseline_schema.py
    # / schema.sql) exactly.
    op.execute("""
        ALTER TABLE prescriptions
            ADD COLUMN IF NOT EXISTS prescriber_name TEXT NOT NULL DEFAULT '',
            ADD COLUMN IF NOT EXISTS ndc_code TEXT NOT NULL DEFAULT '',
            ADD COLUMN IF NOT EXISTS rx_status TEXT NOT NULL DEFAULT '',
            ADD COLUMN IF NOT EXISTS last_fill_date TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS import_source TEXT NOT NULL DEFAULT 'manual',
            ADD COLUMN IF NOT EXISTS walgreens_rx_id TEXT,
            ADD COLUMN IF NOT EXISTS directions TEXT NOT NULL DEFAULT '',
            ADD COLUMN IF NOT EXISTS days_supply INTEGER,
            ADD COLUMN IF NOT EXISTS patient_pay DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS plan_pay DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS dosage_form TEXT NOT NULL DEFAULT '',
            ADD COLUMN IF NOT EXISTS drug_type TEXT NOT NULL DEFAULT ''
    """)
