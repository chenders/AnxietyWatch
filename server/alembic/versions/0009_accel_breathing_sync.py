"""Add accel_spectrograms and derived_breathing_rates tables (syncSchemaVersion 6).

Two new tables mirroring the iOS app's `AccelSpectrogram` and
`DerivedBreathingRate` SwiftData models — the last two tables that were
synced nowhere, so a device migration would have lost them. The Watch
accelerometer pipeline produces one AccelSpectrogram per 10-second FFT
window (tremor / breathing / fidget band power + RMS activity) and one
DerivedBreathingRate per minute of wrist-motion-derived respiration.

PKs are the iOS UUIDs, so the sync path uses `INSERT ... ON CONFLICT
(id) DO UPDATE` for idempotent replays — same contract as hrv_readings
(migration 0005).

session_id is nullable and deliberately NOT a foreign key, unlike
hrv_readings.session_id: these rows are captured on the Watch against
watch-local capture-session IDs that never materialize as
sensor_sessions rows on the phone or the server. An FK would reject
every Watch-origin batch with a violation and 500 the whole /api/sync
POST. The column is still indexed for session-scoped lookups.

Note: this codebase is single-user (no `users` table exists), so neither
table carries a `user_id` foreign key — matching the existing pattern.

Revision ID: 0009
Revises: 0008
Create Date: 2026-07-09
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "accel_spectrograms",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        # Nullable, no FK — see module docstring.
        sa.Column("session_id", postgresql.UUID(as_uuid=True)),
        sa.Column("timestamp", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("tremor_band_power", sa.Float(precision=53), nullable=False),
        sa.Column("breathing_band_power", sa.Float(precision=53), nullable=False),
        sa.Column("fidget_band_power", sa.Float(precision=53), nullable=False),
        sa.Column("activity_level", sa.Float(precision=53), nullable=False),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_accel_spectrograms_session",
        "accel_spectrograms",
        ["session_id"],
        if_not_exists=True,
    )
    op.create_index(
        "idx_accel_spectrograms_timestamp",
        "accel_spectrograms",
        [sa.text("timestamp DESC")],
        if_not_exists=True,
    )

    op.create_table(
        "derived_breathing_rates",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        # Nullable, no FK — see module docstring.
        sa.Column("session_id", postgresql.UUID(as_uuid=True)),
        sa.Column("timestamp", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("breaths_per_minute", sa.Float(precision=53), nullable=False),
        sa.Column("confidence", sa.Float(precision=53), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_derived_breathing_rates_session",
        "derived_breathing_rates",
        ["session_id"],
        if_not_exists=True,
    )
    op.create_index(
        "idx_derived_breathing_rates_timestamp",
        "derived_breathing_rates",
        [sa.text("timestamp DESC")],
        if_not_exists=True,
    )


def downgrade():
    op.drop_index(
        "idx_derived_breathing_rates_timestamp",
        table_name="derived_breathing_rates",
        if_exists=True,
    )
    op.drop_index(
        "idx_derived_breathing_rates_session",
        table_name="derived_breathing_rates",
        if_exists=True,
    )
    op.drop_table("derived_breathing_rates", if_exists=True)
    op.drop_index(
        "idx_accel_spectrograms_timestamp",
        table_name="accel_spectrograms",
        if_exists=True,
    )
    op.drop_index(
        "idx_accel_spectrograms_session",
        table_name="accel_spectrograms",
        if_exists=True,
    )
    op.drop_table("accel_spectrograms", if_exists=True)
