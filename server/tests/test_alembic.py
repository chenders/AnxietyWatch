"""Tests for Alembic migration chain."""

import os
from urllib.parse import urlparse

import psycopg2
from alembic.config import Config
from alembic import command

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get(
        "DATABASE_URL",
        "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test",
    ),
)

# Guard against accidentally running destructive tests on a non-test database.
_db_name = urlparse(DATABASE_URL).path.rsplit("/", 1)[-1]
if "test" not in _db_name:
    raise RuntimeError(
        f"Refusing to run destructive Alembic tests against '{_db_name}'. "
        "DATABASE_URL must point to a database whose name contains 'test'."
    )

ALEMBIC_INI = os.path.join(os.path.dirname(__file__), "..", "alembic.ini")

# Ensure env.py sees the resolved test URL (it reads DATABASE_URL env var
# first). Set once at module level so the intent is explicit, not hidden
# in a helper function.
os.environ["DATABASE_URL"] = DATABASE_URL


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


def _foreign_keys(table):
    """Return a list of (column, references_table, references_column, on_delete)
    tuples for each foreign key constraint on `table`. Used in migration
    tests to assert the FK contract survives upgrade/downgrade rounds."""
    conn = psycopg2.connect(DATABASE_URL)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                kcu.column_name,
                ccu.table_name AS foreign_table,
                ccu.column_name AS foreign_column,
                rc.delete_rule
            FROM information_schema.table_constraints AS tc
            JOIN information_schema.key_column_usage AS kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.constraint_column_usage AS ccu
                ON ccu.constraint_name = tc.constraint_name
            JOIN information_schema.referential_constraints AS rc
                ON rc.constraint_name = tc.constraint_name
            WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = %s
            """,
            (table,),
        )
        rows = cur.fetchall()
    conn.close()
    return rows


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
        # 0004 — per-sample provenance tables and JSONB column
        assert "quantity_health_samples" in tables
        assert "sleep_stage_events" in tables
        assert "data_quality" in _column_names("health_snapshots")
        # 0005 — Polar H10 sensor_sessions + hrv_readings
        assert "sensor_sessions" in tables
        assert "hrv_readings" in tables
        cols = _column_names("hrv_readings")
        assert {"session_id", "rmssd", "lf_power", "source"}.issubset(cols)
        # FK enforcement: hrv_readings.session_id must actually reference
        # sensor_sessions.id with CASCADE on delete. A column-only check
        # would silently pass if a future migration dropped the FK while
        # keeping the column.
        fks = _foreign_keys("hrv_readings")
        assert any(
            col == "session_id"
            and ref_table == "sensor_sessions"
            and ref_col == "id"
            and on_delete == "CASCADE"
            for col, ref_table, ref_col, on_delete in fks
        ), f"Expected CASCADE FK hrv_readings.session_id -> sensor_sessions.id; got {fks}"
        # 0009 — Watch accelerometer accel_spectrograms + derived_breathing_rates
        assert "accel_spectrograms" in tables
        assert "derived_breathing_rates" in tables
        accel_cols = _column_names("accel_spectrograms")
        assert {"session_id", "tremor_band_power", "breathing_band_power",
                "fidget_band_power", "activity_level"}.issubset(accel_cols)
        rate_cols = _column_names("derived_breathing_rates")
        assert {"session_id", "breaths_per_minute", "confidence", "source"}.issubset(rate_cols)
        # session_id on both tables is deliberately NOT a foreign key:
        # Watch-side capture-session IDs never materialize as
        # sensor_sessions rows, so a constraint would 500 every
        # Watch-origin /api/sync batch. Pin the absence so a future
        # migration doesn't "helpfully" add one.
        assert not _foreign_keys("accel_spectrograms"), (
            "accel_spectrograms.session_id must stay FK-free (Watch session "
            "IDs have no server-side parent)"
        )
        assert not _foreign_keys("derived_breathing_rates"), (
            "derived_breathing_rates.session_id must stay FK-free (Watch "
            "session IDs have no server-side parent)"
        )

    def test_round_trip(self):
        """Upgrade to head, downgrade to base, upgrade again."""
        cfg = _alembic_cfg()
        command.upgrade(cfg, "head")
        command.downgrade(cfg, "0001")
        # Data fix downgrade goes back to baseline — verify tables still exist
        # and that the 0004 + 0005 additions have been removed.
        tables = _table_names()
        assert "health_snapshots" in tables
        assert "quantity_health_samples" not in tables
        assert "sleep_stage_events" not in tables
        assert "data_quality" not in _column_names("health_snapshots")
        assert "sensor_sessions" not in tables
        assert "hrv_readings" not in tables
        assert "accel_spectrograms" not in tables
        assert "derived_breathing_rates" not in tables
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


class TestFlaskInitDb:
    """Test that the Flask init-db command uses Alembic."""

    def setup_method(self):
        _reset_db()

    def test_init_db_command_creates_tables(self, monkeypatch):
        """The Flask init-db CLI command should apply all migrations."""
        monkeypatch.setenv("DATABASE_URL", DATABASE_URL)
        from server import create_app
        app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
        runner = app.test_cli_runner()
        result = runner.invoke(args=["init-db"])
        assert result.exit_code == 0
        assert "Database initialized" in result.output

        tables = _table_names()
        assert "analyses" in tables
        assert "songs" in tables
