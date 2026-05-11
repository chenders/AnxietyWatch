"""Add sensor_sessions and hrv_readings tables for Polar H10 sync.

Two new tables that mirror the iOS app's `SensorSession` and `HRVReading`
SwiftData models. The iOS BLE service produces one `SensorSession` per
recorded H10 wear (foreground stress check or overnight), with per-minute
`HRVReading` rows attached. The session row also carries an optional
gzipped raw RR-interval archive (BYTEA) that the iOS side compresses at
upload time — small enough to fit comfortably in BYTEA at ~120 KB/night
gzipped, and keeping it on the parent row simplifies retention.

PKs are the iOS UUIDs (= `SensorSession.id` / `HRVReading.id`), so the
sync path uses `INSERT ... ON CONFLICT (id) DO UPDATE` for idempotent
replays and partial-row updates (start row first → fill summary later →
optionally attach archive). hrv_readings.session_id is a FK back to
sensor_sessions with CASCADE so deleting a session cleans up its
children.

Note: this codebase is single-user (no `users` table exists), so neither
table carries a `user_id` foreign key — matching the existing pattern of
`quantity_health_samples`, `health_snapshots`, etc.

Revision ID: 0005
Revises: 0004
Create Date: 2026-05-11
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "sensor_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("start_time", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("end_time", sa.TIMESTAMP(timezone=True)),
        sa.Column("battery_at_start", sa.Integer()),
        sa.Column("interruption_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("summary_json", postgresql.JSONB(astext_type=sa.Text())),
        sa.Column("rr_archive", sa.LargeBinary()),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        if_not_exists=True,
    )
    op.create_index(
        "idx_sensor_sessions_source_start",
        "sensor_sessions",
        ["source", sa.text("start_time DESC")],
        if_not_exists=True,
    )

    op.create_table(
        "hrv_readings",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "session_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("sensor_sessions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("timestamp", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("rmssd", sa.Float(precision=53), nullable=False),
        sa.Column("sdnn", sa.Float(precision=53), nullable=False),
        sa.Column("pnn50", sa.Float(precision=53), nullable=False),
        # LF / HF / ratio are nullable per the Phase 1 design note: per-
        # minute windows with <30 RR intervals can compute time-domain HRV
        # but not frequency-domain. iOS side writes the values when the
        # window had ≥30 intervals, NULL otherwise.
        sa.Column("lf_power", sa.Float(precision=53)),
        sa.Column("hf_power", sa.Float(precision=53)),
        sa.Column("lf_hf_ratio", sa.Float(precision=53)),
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
        "idx_hrv_readings_session",
        "hrv_readings",
        ["session_id"],
        if_not_exists=True,
    )
    op.create_index(
        "idx_hrv_readings_timestamp",
        "hrv_readings",
        [sa.text("timestamp DESC")],
        if_not_exists=True,
    )


def downgrade():
    op.drop_index("idx_hrv_readings_timestamp", table_name="hrv_readings", if_exists=True)
    op.drop_index("idx_hrv_readings_session", table_name="hrv_readings", if_exists=True)
    op.drop_table("hrv_readings", if_exists=True)
    op.drop_index("idx_sensor_sessions_source_start", table_name="sensor_sessions", if_exists=True)
    op.drop_table("sensor_sessions", if_exists=True)
