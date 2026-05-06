"""Add quantity_health_samples, sleep_stage_events, and data_quality column.

Adds two new per-sample tables that mirror the iOS app's
`QuantityHealthSample` and `SleepStageEvent` SwiftData models, plus a
`data_quality` JSONB column on `health_snapshots` carrying the per-metric
reliability + source-summary block emitted by the SnapshotAggregator.

- `quantity_health_samples`: one row per HealthKit `HKQuantitySample` we
  capture (HR, HRV, glucose, SpO2, BP, body/wrist temp, etc.). The `id`
  PK is the iOS UUID (= `HKSample.uuid`), so `INSERT ... ON CONFLICT (id)
  DO UPDATE` is the dedupe path for replays + retroactive corrections.
- `sleep_stage_events`: one row per `HKCategorySample` sleep stage,
  with start/end and provenance.
- `health_snapshots.data_quality`: JSONB
  `{glucose: {reliability, sources}, spo2: {...}, ...}` per day.

Note: this codebase is single-user (no `users` table exists), so neither
table carries a `user_id` foreign key — matching the existing pattern of
`anxiety_entries`, `health_snapshots`, `barometric_readings`, etc.

Revision ID: 0004
Revises: 0003
Create Date: 2026-05-05
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "quantity_health_samples",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("timestamp", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("metric_type", sa.Text(), nullable=False),
        sa.Column("value", sa.Float(precision=53), nullable=False),
        sa.Column("unit_string", sa.Text(), nullable=False),
        sa.Column("source_bundle_id", sa.Text(), nullable=False),
        sa.Column("source_name", sa.Text()),
        sa.Column("device_model", sa.Text()),
        sa.Column("group_id", postgresql.UUID(as_uuid=True)),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_quantity_samples_metric_time",
        "quantity_health_samples",
        ["metric_type", sa.text("timestamp DESC")],
        if_not_exists=True,
    )
    op.create_index(
        "idx_quantity_samples_group",
        "quantity_health_samples",
        ["group_id"],
        if_not_exists=True,
    )

    op.create_table(
        "sleep_stage_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("start_time", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("end_time", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("stage", sa.Text(), nullable=False),
        sa.Column("source_bundle_id", sa.Text(), nullable=False),
        sa.Column("source_name", sa.Text()),
        sa.Column("device_model", sa.Text()),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_sleep_events_start",
        "sleep_stage_events",
        [sa.text("start_time DESC")],
        if_not_exists=True,
    )

    op.add_column(
        "health_snapshots",
        sa.Column("data_quality", postgresql.JSONB(astext_type=sa.Text())),
        if_not_exists=True,
    )


def downgrade():
    op.drop_column("health_snapshots", "data_quality", if_exists=True)
    op.drop_index(
        "idx_sleep_events_start",
        table_name="sleep_stage_events",
        if_exists=True,
    )
    op.drop_table("sleep_stage_events", if_exists=True)
    op.drop_index(
        "idx_quantity_samples_group",
        table_name="quantity_health_samples",
        if_exists=True,
    )
    op.drop_index(
        "idx_quantity_samples_metric_time",
        table_name="quantity_health_samples",
        if_exists=True,
    )
    op.drop_table("quantity_health_samples", if_exists=True)
