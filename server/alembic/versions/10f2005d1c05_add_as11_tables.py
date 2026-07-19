"""add_as11_tables

Revision ID: 10f2005d1c05
Revises: 8d7458bd88ef
Create Date: 2026-07-19 03:27:14.629227
"""
from alembic import op
import sqlalchemy as sa


revision = '10f2005d1c05'
down_revision = '8d7458bd88ef'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'as11_therapy_session',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('bridge_id', sa.String(), nullable=False),
        sa.Column('start_utc', sa.DateTime(timezone=True), nullable=False),
        sa.Column('end_utc', sa.DateTime(timezone=True), nullable=True),
        sa.Column('mode', sa.String(), nullable=True),
        sa.Column('set_pressure', sa.Float(), nullable=True),
        sa.Column('min_pressure', sa.Float(), nullable=True),
        sa.Column('max_pressure', sa.Float(), nullable=True),
        sa.Column('median_pressure', sa.Float(), nullable=True),
        sa.Column('p95_leak', sa.Float(), nullable=True),
        sa.Column('ahi', sa.Float(), nullable=True),
        sa.Column('event_counts', sa.JSON(), nullable=True),
        sa.Column('mask_on_fraction', sa.Float(), nullable=True),
        sa.Column('source', sa.String(), nullable=False),
        sa.Column('settings_snapshot', sa.JSON(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index('idx_as11_therapy_session_start', 'as11_therapy_session', ['start_utc'])

    op.create_table(
        'as11_stream_sample',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('bridge_id', sa.String(), nullable=False),
        sa.Column('ts_utc', sa.DateTime(timezone=True), nullable=False),
        sa.Column('channel', sa.String(), nullable=False),
        sa.Column('value', sa.Float(), nullable=False),
        sa.Column('unit', sa.String(), nullable=True),
        sa.Column('ingest_ts_utc', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column(
            'session_id',
            sa.Integer(),
            sa.ForeignKey(
                'as11_therapy_session.id',
                ondelete='SET NULL'),
            nullable=True),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index('idx_as11_stream_sample_ts', 'as11_stream_sample', ['ts_utc'])


def downgrade():
    op.drop_index('idx_as11_stream_sample_ts', table_name='as11_stream_sample')
    op.drop_table('as11_stream_sample')
    op.drop_index('idx_as11_therapy_session_start', table_name='as11_therapy_session')
    op.drop_table('as11_therapy_session')
