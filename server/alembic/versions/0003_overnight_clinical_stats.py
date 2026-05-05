"""Add overnight clinical stats columns to health_snapshots.

Adds the seven derived clinical fields introduced by the iOS app's
overnight stats UI work (PR #120):

- spo2_nadir_overnight        DOUBLE PRECISION  -- worst SpO2 % during sleep
- spo2_time_below_90_min      INTEGER           -- T90 minutes
- spo2_desats_count           INTEGER           -- rough ODI-style event count
- glucose_std_dev             DOUBLE PRECISION  -- daily glucose SD (mg/dL)
- glucose_cv                  DOUBLE PRECISION  -- coefficient of variation (%)
- glucose_min                 DOUBLE PRECISION  -- daily lowest reading
- glucose_max                 DOUBLE PRECISION  -- daily highest reading

All seven are nullable. The iOS aggregator emits nil for sparse-data
days that don't satisfy the count + monitored-duration thresholds, and
the sync payload may omit them entirely on older app builds.

Revision ID: 0003
Revises: 0002
Create Date: 2026-05-05
"""
from alembic import op


revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


_NEW_COLUMNS = [
    ("spo2_nadir_overnight", "DOUBLE PRECISION"),
    ("spo2_time_below_90_min", "INTEGER"),
    ("spo2_desats_count", "INTEGER"),
    ("glucose_std_dev", "DOUBLE PRECISION"),
    ("glucose_cv", "DOUBLE PRECISION"),
    ("glucose_min", "DOUBLE PRECISION"),
    ("glucose_max", "DOUBLE PRECISION"),
]


def upgrade():
    for name, sql_type in _NEW_COLUMNS:
        op.execute(
            f"ALTER TABLE health_snapshots "
            f"ADD COLUMN IF NOT EXISTS {name} {sql_type}"
        )


def downgrade():
    for name, _ in _NEW_COLUMNS:
        op.execute(f"ALTER TABLE health_snapshots DROP COLUMN IF EXISTS {name}")
