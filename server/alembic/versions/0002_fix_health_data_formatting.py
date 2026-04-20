"""Fix health data formatting issues in health_snapshots.

1. SpO2: multiply by 100 where values are on 0-1 scale
2. Skin temp: move absolute wrist temps to skin_temp_wrist, clear
   skin_temp_deviation
3. Sleep: cap sleep_duration_min to stage sum where stages exceed it

All operations are idempotent — safe to run on databases where the
standalone migration was already applied manually.

Originally: server/migrations/fix_2026_04_17_health_data_formatting.py

Revision ID: 0002
Revises: 0001
Create Date: 2026-04-19
"""
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    # 1. SpO2: scale 0-1 values to 0-100.
    # Values already on 0-100 scale are > 1.0 and won't match.
    op.execute(
        "UPDATE health_snapshots SET spo2_avg = spo2_avg * 100 "
        "WHERE spo2_avg IS NOT NULL AND spo2_avg <= 1.0"
    )

    # 2. Skin temp: values with ABS > 5 are absolute temps, not deviations.
    # Move them to skin_temp_wrist and clear the deviation.
    op.execute(
        "UPDATE health_snapshots "
        "SET skin_temp_wrist = skin_temp_deviation, "
        "    skin_temp_deviation = NULL "
        "WHERE skin_temp_deviation IS NOT NULL "
        "AND ABS(skin_temp_deviation) > 5.0"
    )

    # 3. Sleep: where stage sum exceeds duration, set duration to stage sum.
    op.execute(
        "UPDATE health_snapshots "
        "SET sleep_duration_min = COALESCE(sleep_deep_min, 0) "
        "  + COALESCE(sleep_rem_min, 0) + COALESCE(sleep_core_min, 0) "
        "WHERE sleep_duration_min IS NOT NULL "
        "AND (COALESCE(sleep_deep_min, 0) + COALESCE(sleep_rem_min, 0) "
        "   + COALESCE(sleep_core_min, 0)) > sleep_duration_min"
    )


def downgrade():
    # Data transformations are not reversible — original values are lost.
    # Downgrade to 0001 (schema-only) is safe; the schema itself is
    # unchanged by this migration.
    pass
