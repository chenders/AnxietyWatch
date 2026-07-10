"""Add by-session import fields to cpap_sessions.

The OSCAR by-session CSV import (iOS `CPAPImporter.importOSCARBySession`)
aggregates per-session rows into daily values and carries eight fields the
daily formats never reported: RDI, RERA count, machine-attached-oximeter
SpO2/pulse stats, 95th-percentile pressure, and average/max leak.

All eight columns are nullable with NO default: NULL means "the source did
not report this value" (e.g. a machine without an attached oximeter exports
empty SpO2 columns), which must stay distinguishable from a measured 0 —
same null-honesty contract as the nullable ahi column (migration 0007).

Units: rdi_events events/hour (a rate, like ahi — not a count);
rera_events count; spo2_avg/spo2_min %; pulse_avg bpm; pressure_95th cmH2O;
leak_avg/leak_max L/min.

IF NOT EXISTS because schema.sql (executed eagerly by the 0001 upgrade)
already declares these columns — same convention as migration 0009's
if_not_exists tables.

Revision ID: 0010
Revises: 0009
Create Date: 2026-07-10
"""
from alembic import op


revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None

# (name, type) pairs for the eight by-session columns, shared by both
# directions so upgrade and downgrade can never drift apart.
BY_SESSION_COLUMNS = (
    ("rdi_events", "DOUBLE PRECISION"),
    ("rera_events", "INTEGER"),
    ("spo2_avg", "DOUBLE PRECISION"),
    ("spo2_min", "DOUBLE PRECISION"),
    ("pulse_avg", "DOUBLE PRECISION"),
    ("pressure_95th", "DOUBLE PRECISION"),
    ("leak_avg", "DOUBLE PRECISION"),
    ("leak_max", "DOUBLE PRECISION"),
)


def upgrade():
    for name, column_type in BY_SESSION_COLUMNS:
        op.execute(
            f"ALTER TABLE cpap_sessions ADD COLUMN IF NOT EXISTS {name} {column_type}"
        )


def downgrade():
    # Lossy: any synced by-session values are discarded. The columns came
    # from schema.sql on the 0001 upgrade path too, so (matching the 0009
    # precedent) this downgrade owns their removal.
    for name, _ in BY_SESSION_COLUMNS:
        op.execute(f"ALTER TABLE cpap_sessions DROP COLUMN IF EXISTS {name}")
