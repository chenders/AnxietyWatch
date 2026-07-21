"""add_source_to_session_sample_buffer

Sub-project C Task 5: add the per-sensor ``source`` discriminator to
``session_sample_buffer`` so the backstop can evaluate each SpO2 source
independently (a normal reading from one concurrently-active source must not
mask a sustained low on another).

A separate migration rather than editing c5d7e9f10a2b: that revision already
shipped (PR #30), so a DB that applied it won't re-run it. ``if_not_exists`` /
``if_exists`` keep this a no-op on a fresh DB where baseline 0001's schema.sql
replay already created the column.

Revision ID: d6e8fa0b1c34
Revises: c5d7e9f10a2b
Create Date: 2026-07-21 06:00:00.000000
"""
from alembic import op
import sqlalchemy as sa


revision = 'd6e8fa0b1c34'
down_revision = 'c5d7e9f10a2b'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('session_sample_buffer', sa.Column('source', sa.Text(), nullable=True),
                  if_not_exists=True)


def downgrade():
    op.drop_column('session_sample_buffer', 'source', if_exists=True)
