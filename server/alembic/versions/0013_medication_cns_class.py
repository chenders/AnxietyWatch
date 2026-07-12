"""Add medication_definitions.cns_depressant_class.

The iOS app's explicit CNS-depressant classification picker
(MedicationDefinition.cnsDepressantClass — the source of truth for the
klaxon feature's §14.1 dose-window monitoring) was previously not synced:
a device restore silently dropped it to NULL and the app re-defaulted the
classification by name-guessing, which can under-monitor (e.g. an explicit
opioidER's 24h window re-guessed as opioidIR's 8h, or nil). Additive
nullable TEXT column; NULL = not a CNS depressant / unclassified. Raw
CNSDepressantClass rawValue strings (e.g. "benzodiazepine", "opioidER",
"methadoneOrUnknownLongActing") — the server stores, never interprets.

Revision ID: 0013
Revises: 0012
"""
from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade():
    # IF NOT EXISTS (0011/0012 pattern): schema.sql also creates this column
    # eagerly on fresh installs, so the upgrade must be a no-op there.
    op.execute(
        "ALTER TABLE medication_definitions "
        "ADD COLUMN IF NOT EXISTS cns_depressant_class TEXT"
    )


def downgrade():
    op.execute(
        "ALTER TABLE medication_definitions "
        "DROP COLUMN IF EXISTS cns_depressant_class"
    )
