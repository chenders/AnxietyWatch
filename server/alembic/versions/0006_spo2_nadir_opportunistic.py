"""Add spo2_nadir_opportunistic column to health_snapshots.

Source-stratified SpO2 nadir storage. `spo2_nadir_overnight` was
previously the only nadir column on a snapshot — and it took whichever
source HealthKit reported as the daily minimum, mixing dedicated
overnight pulse oximeters (EMAY, Wellue) with opportunistic Apple
Watch wrist reads. A positional artifact on the Watch (arm shifting
off the sensor, pooling blood) could read as a 0.78 nadir even when
the dedicated oximeter recorded 0.92 for the same night.

After PR #142 the iOS aggregator applies source precedence:
`spo2_nadir_overnight` is populated from the high-fidelity tier when
any overnight oximeter covered the window, falling back to
opportunistic samples only when no dedicated device was present.
The new `spo2_nadir_opportunistic` column carries the Apple-Watch-only
nadir for the same window — kept separate so the Trends chart can
plot a second line showing the opportunistic source for nights where
both devices have data.

Nullable: nil when no opportunistic SpO2 samples covered the
overnight window, and on legacy snapshots written before this
migration ran on the iOS aggregator.

Revision ID: 0006
Revises: 0005
Create Date: 2026-05-13
"""
from alembic import op


revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(
        "ALTER TABLE health_snapshots "
        "ADD COLUMN IF NOT EXISTS spo2_nadir_opportunistic DOUBLE PRECISION"
    )


def downgrade():
    op.execute(
        "ALTER TABLE health_snapshots DROP COLUMN IF EXISTS spo2_nadir_opportunistic"
    )
