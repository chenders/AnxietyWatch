"""Tests for Alembic migration chain."""

import os

import psycopg2
import pytest
from alembic.config import Config
from alembic import command

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get(
        "DATABASE_URL",
        "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test",
    ),
)

ALEMBIC_INI = os.path.join(os.path.dirname(__file__), "..", "alembic.ini")


def _alembic_cfg():
    """Build an Alembic config pointing at the test database."""
    cfg = Config(ALEMBIC_INI)
    cfg.set_main_option("sqlalchemy.url", DATABASE_URL)
    return cfg


def _reset_db():
    """Drop and recreate the public schema for a clean slate."""
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("DROP SCHEMA IF EXISTS public CASCADE")
        cur.execute("CREATE SCHEMA public")
    conn.close()


def _table_names():
    """Return a set of user table names in the public schema."""
    conn = psycopg2.connect(DATABASE_URL)
    with conn.cursor() as cur:
        cur.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        )
        names = {row[0] for row in cur.fetchall()}
    conn.close()
    return names


def _column_names(table):
    """Return a set of column names for a given table."""
    conn = psycopg2.connect(DATABASE_URL)
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = %s",
            (table,),
        )
        names = {row[0] for row in cur.fetchall()}
    conn.close()
    return names


class TestBaselineMigration:
    """Test that the baseline migration creates the full schema."""

    def setup_method(self):
        _reset_db()

    def test_upgrade_creates_all_tables(self):
        command.upgrade(_alembic_cfg(), "0001")
        tables = _table_names()
        expected = {
            "api_keys", "anxiety_entries", "medication_definitions",
            "medication_doses", "cpap_sessions", "health_snapshots",
            "barometric_readings", "sync_log", "pharmacies",
            "prescriptions", "pharmacy_call_logs", "settings",
            "correlations", "analyses", "therapy_sessions",
            "patient_profile", "psychiatrist_profile", "conflicts",
            "analysis_jobs", "songs", "song_occurrences",
        }
        missing = expected - tables
        assert not missing, f"Missing tables after baseline: {missing}"

    def test_baseline_includes_historical_columns(self):
        """Verify columns from historical inline migrations are present."""
        command.upgrade(_alembic_cfg(), "0001")
        # Walgreens/CapRx columns on prescriptions
        rx_cols = _column_names("prescriptions")
        for col in ("walgreens_rx_id", "directions", "days_supply",
                     "patient_pay", "dosage_form"):
            assert col in rx_cols, f"prescriptions.{col} missing"
        # Health snapshot extensions
        hs_cols = _column_names("health_snapshots")
        for col in ("cpap_ahi", "cpap_usage_minutes",
                     "barometric_pressure_avg_kpa", "skin_temp_wrist"):
            assert col in hs_cols, f"health_snapshots.{col} missing"
        # Analyses dose_tracking_incomplete
        an_cols = _column_names("analyses")
        assert "dose_tracking_incomplete" in an_cols

    def test_downgrade_removes_all_tables(self):
        command.upgrade(_alembic_cfg(), "0001")
        command.downgrade(_alembic_cfg(), "base")
        tables = _table_names()
        # Only alembic_version should remain (Alembic cleans it up, but
        # it may linger depending on version). User tables should be gone.
        user_tables = tables - {"alembic_version"}
        assert not user_tables, f"Tables remain after downgrade: {user_tables}"


class TestFullMigrationChain:
    """Test upgrading all the way to head and back."""

    def setup_method(self):
        _reset_db()

    def test_upgrade_to_head(self):
        command.upgrade(_alembic_cfg(), "head")
        tables = _table_names()
        assert "analyses" in tables
        assert "songs" in tables

    def test_round_trip(self):
        """Upgrade to head, downgrade to base, upgrade again."""
        cfg = _alembic_cfg()
        command.upgrade(cfg, "head")
        command.downgrade(cfg, "0001")
        # Data fix downgrade goes back to baseline — verify tables still exist
        tables = _table_names()
        assert "health_snapshots" in tables
        command.downgrade(cfg, "base")
        tables = _table_names()
        user_tables = tables - {"alembic_version"}
        assert not user_tables


class TestStampExistingDatabase:
    """Test the production cutover path: schema exists, stamp to head."""

    def setup_method(self):
        _reset_db()

    def test_stamp_then_upgrade_is_noop(self):
        # Simulate existing DB: apply schema.sql directly
        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        schema_path = os.path.join(
            os.path.dirname(__file__), "..", "schema.sql"
        )
        with open(schema_path) as f:
            with conn.cursor() as cur:
                cur.execute(f.read())
        conn.close()

        # Stamp as if all migrations already ran
        cfg = _alembic_cfg()
        command.stamp(cfg, "head")

        # Upgrade should be a no-op (already at head)
        command.upgrade(cfg, "head")

        # Tables should still exist and be intact
        tables = _table_names()
        assert "analyses" in tables
        assert "songs" in tables
