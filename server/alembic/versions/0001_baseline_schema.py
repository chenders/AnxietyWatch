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

As of migration 0011, the Walgreens/CapRx prescription columns listed above
are no longer part of schema.sql, so a fresh `upgrade()` here — which just
replays schema.sql — does not create them. 0011 is what drops them from
databases that were built before the trim.

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
    # 0005 — Polar H10 sensor_sessions + hrv_readings. Added here too
    # because schema.sql (which the 0001 upgrade replays for fresh DBs)
    # creates them eagerly; the 0001 downgrade needs to know about them
    # so the test_round_trip / test_downgrade_removes_all_tables paths
    # leave a clean slate.
    op.execute("DROP TABLE IF EXISTS hrv_readings CASCADE")
    op.execute("DROP TABLE IF EXISTS sensor_sessions CASCADE")
    # 0009 — Watch accelerometer accel_spectrograms + derived_breathing_rates.
    # Same rationale as the 0005 pair above: schema.sql creates them eagerly
    # on the 0001 upgrade, so the 0001 downgrade must drop them too.
    op.execute("DROP TABLE IF EXISTS derived_breathing_rates CASCADE")
    op.execute("DROP TABLE IF EXISTS accel_spectrograms CASCADE")
    op.execute("DROP TABLE IF EXISTS sleep_stage_events CASCADE")
    op.execute("DROP TABLE IF EXISTS quantity_health_samples CASCADE")
    op.execute("DROP TABLE IF EXISTS barometric_readings CASCADE")
    op.execute("DROP TABLE IF EXISTS health_snapshots CASCADE")
    op.execute("DROP TABLE IF EXISTS cpap_sessions CASCADE")
    op.execute("DROP TABLE IF EXISTS medication_doses CASCADE")
    op.execute("DROP TABLE IF EXISTS medication_definitions CASCADE")
    op.execute("DROP TABLE IF EXISTS anxiety_entries CASCADE")
    op.execute("DROP TABLE IF EXISTS api_keys CASCADE")

    # Tables added in later migrations but present in schema.sql for fresh DBs:
    op.execute("DROP TABLE IF EXISTS oura_daily CASCADE")
    op.execute("DROP TABLE IF EXISTS oura_sleep CASCADE")
    op.execute("DROP TABLE IF EXISTS oura_heartrate CASCADE")
    op.execute("DROP TABLE IF EXISTS oura_ibi CASCADE")
    op.execute("DROP TABLE IF EXISTS oura_credentials CASCADE")
    op.execute("DROP TABLE IF EXISTS delta_sync_log CASCADE")
    op.execute("DROP TABLE IF EXISTS sample_tombstones CASCADE")
    op.execute("DROP TABLE IF EXISTS samples CASCADE")
    op.execute("DROP TABLE IF EXISTS as11_stream_sample CASCADE")
    op.execute("DROP TABLE IF EXISTS as11_therapy_session CASCADE")
