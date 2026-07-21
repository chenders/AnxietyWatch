"""add_alert_channel_tables

Sub-project C (server redundant alert channel): sample buffer for the
conservative backstop + no-data heartbeat, APNs device tokens, and an
alert_event ledger for push idempotency. Kept identical to schema.sql.

Revision ID: c5d7e9f10a2b
Revises: 10f2005d1c05
Create Date: 2026-07-21 00:00:00.000000
"""
from alembic import op
import sqlalchemy as sa


revision = 'c5d7e9f10a2b'
down_revision = '10f2005d1c05'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'session_sample_buffer',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('session_id', sa.Text(), nullable=False),
        sa.Column('ts_utc', sa.DateTime(timezone=True), nullable=False),
        sa.Column('channel', sa.Text(), nullable=False),
        sa.Column('value', sa.Float(), nullable=False),
        sa.Column('ingest_ts_utc', sa.DateTime(timezone=True),
                  server_default=sa.text('now()'), nullable=False),
        if_not_exists=True
    )
    op.create_index('idx_session_sample_buffer_session_ts', 'session_sample_buffer',
                    ['session_id', sa.text('ts_utc DESC')], if_not_exists=True)
    # Supports the heartbeat sweep's per-session MAX(ingest_ts_utc) lookup.
    op.create_index('idx_session_sample_buffer_session_ingest', 'session_sample_buffer',
                    ['session_id', sa.text('ingest_ts_utc DESC')], if_not_exists=True)

    op.create_table(
        'device_push_token',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('token', sa.Text(), nullable=False, unique=True),
        sa.Column('env', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True),
                  server_default=sa.text('now()'), nullable=False),
        if_not_exists=True
    )

    op.create_table(
        'alert_event',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('session_id', sa.Text(), nullable=False),
        sa.Column('kind', sa.Text(), nullable=False),
        sa.Column('ts_utc', sa.DateTime(timezone=True),
                  server_default=sa.text('now()'), nullable=False),
        if_not_exists=True
    )
    # UNIQUE so a concurrent append/sweep can't create a duplicate (session_id,
    # kind) row (INSERT ... ON CONFLICT DO NOTHING). The push is delivery-gated
    # (the row is written only after a successful push), so at most one row
    # exists per event; a rare same-key race may still double-push, which is
    # acceptable for a redundant channel. Matches schema.sql.
    op.create_index('idx_alert_event_session_kind', 'alert_event',
                    ['session_id', 'kind'], unique=True, if_not_exists=True)


def downgrade():
    op.drop_index('idx_alert_event_session_kind', table_name='alert_event', if_exists=True)
    op.drop_table('alert_event', if_exists=True)
    op.drop_table('device_push_token', if_exists=True)
    op.drop_index('idx_session_sample_buffer_session_ingest',
                  table_name='session_sample_buffer', if_exists=True)
    op.drop_index('idx_session_sample_buffer_session_ts',
                  table_name='session_sample_buffer', if_exists=True)
    op.drop_table('session_sample_buffer', if_exists=True)
