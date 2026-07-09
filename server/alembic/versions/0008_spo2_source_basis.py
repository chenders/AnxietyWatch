"""Add SpO2 source-basis columns to health_snapshots (F-092).

A night's overnight SpO2 profile can legitimately mix two source
populations: the avg/nadir may come from a dedicated overnight pulse
oximeter (EMAY/Wellue) that connected only briefly, while the T90 /
desaturation counts come from the broader HealthKit-direct set (Apple
Watch + oximeter) because only that set was dense enough to clear the
continuous-monitoring sufficiency gate (the F-023 behavior). Each field
is individually correct, but presenting them together undisclosed lets a
reader assume they describe the same sample population.

These two TEXT columns record which basis produced each metric group so
the iOS clinical surfaces (Last-Night card, CPAP detail, clinician PDF)
can disclose the divergence:

- spo2_aggregate_source — basis for spo2_avg / spo2_nadir_overnight
- spo2_burden_source    — basis for spo2_time_below_90_min / spo2_desats_count

Value domain: 'oximeter' | 'mixed'. Nullable: nil when that metric group
wasn't computed for the window, and on legacy snapshots written before
the iOS aggregator started tagging the basis (syncSchemaVersion 5).

Revision ID: 0008
Revises: 0007
Create Date: 2026-07-09
"""
from alembic import op


revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(
        "ALTER TABLE health_snapshots "
        "ADD COLUMN IF NOT EXISTS spo2_aggregate_source TEXT"
    )
    op.execute(
        "ALTER TABLE health_snapshots "
        "ADD COLUMN IF NOT EXISTS spo2_burden_source TEXT"
    )


def downgrade():
    op.execute(
        "ALTER TABLE health_snapshots DROP COLUMN IF EXISTS spo2_burden_source"
    )
    op.execute(
        "ALTER TABLE health_snapshots DROP COLUMN IF EXISTS spo2_aggregate_source"
    )
