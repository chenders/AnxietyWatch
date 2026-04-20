"""Baseline schema — full current database structure.

Consolidates all prior ad-hoc migrations that were in init_db():
- CPAP columns made nullable (pressure_min/max/mean, leak_rate_95th)
- Walgreens prescription columns (prescriber_name, ndc_code, rx_status,
  last_fill_date, import_source, walgreens_rx_id, directions)
- CapRx prescription columns (days_supply, patient_pay, plan_pay,
  dosage_form, drug_type)
- Health snapshot extensions (cpap_ahi, cpap_usage_minutes,
  barometric_pressure_avg_kpa, barometric_pressure_change_kpa,
  skin_temp_wrist)
- Correlations table
- Analyses table + dose_tracking_incomplete column

For existing databases: run `alembic stamp 0001` to mark as applied
without executing.

Revision ID: 0001
Revises: (none)
Create Date: 2026-04-19
"""
import os

from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    schema_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "schema.sql"
    )
    with open(schema_path) as f:
        op.execute(f.read())


def downgrade():
    # Drop in reverse dependency order to respect foreign keys.
    op.execute("DROP TABLE IF EXISTS song_occurrences CASCADE")
    op.execute("DROP TABLE IF EXISTS songs CASCADE")
    op.execute("DROP TABLE IF EXISTS analysis_jobs CASCADE")
    op.execute("DROP TABLE IF EXISTS analyses CASCADE")
    op.execute("DROP TABLE IF EXISTS conflicts CASCADE")
    op.execute("DROP TABLE IF EXISTS psychiatrist_profile CASCADE")
    op.execute("DROP TABLE IF EXISTS patient_profile CASCADE")
    op.execute("DROP TABLE IF EXISTS therapy_sessions CASCADE")
    op.execute("DROP TABLE IF EXISTS correlations CASCADE")
    op.execute("DROP TABLE IF EXISTS settings CASCADE")
    op.execute("DROP TABLE IF EXISTS pharmacy_call_logs CASCADE")
    op.execute("DROP TABLE IF EXISTS prescriptions CASCADE")
    op.execute("DROP TABLE IF EXISTS pharmacies CASCADE")
    op.execute("DROP TABLE IF EXISTS sync_log CASCADE")
    op.execute("DROP TABLE IF EXISTS barometric_readings CASCADE")
    op.execute("DROP TABLE IF EXISTS health_snapshots CASCADE")
    op.execute("DROP TABLE IF EXISTS cpap_sessions CASCADE")
    op.execute("DROP TABLE IF EXISTS medication_doses CASCADE")
    op.execute("DROP TABLE IF EXISTS medication_definitions CASCADE")
    op.execute("DROP TABLE IF EXISTS anxiety_entries CASCADE")
    op.execute("DROP TABLE IF EXISTS api_keys CASCADE")
