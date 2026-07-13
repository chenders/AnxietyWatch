"""Tests for Alembic migration chain."""

import os
from urllib.parse import urlparse

import psycopg2
import psycopg2.errors
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
        # 0010 — CPAP by-session fields (all nullable; NULL = "not reported")
        cpap_cols = _column_names("cpap_sessions")
        assert {"rdi_events", "rera_events", "spo2_avg", "spo2_min",
                "pulse_avg", "pressure_95th", "leak_avg", "leak_max"}.issubset(cpap_cols)
        # 0011 — pharmacy-import columns dropped from prescriptions
        rx_cols = _column_names("prescriptions")
        assert not {"prescriber_name", "ndc_code", "rx_status", "last_fill_date",
                    "import_source", "walgreens_rx_id", "directions", "days_supply",
                    "patient_pay", "plan_pay", "dosage_form", "drug_type"} & rx_cols, (
            f"0011 should have dropped all pharmacy-import columns; found {rx_cols}"
        )
        # 0012 — supply-tracking columns dropped from prescriptions
        assert rx_cols == {
            "rx_number", "medication_name", "dose_mg", "dose_description",
            "date_filled", "pharmacy_name", "notes",
        }, f"0012 should leave prescriptions with exactly the 7 core columns; found {rx_cols}"
        # 0013 — explicit CNS-depressant classification synced from the app
        assert "cns_depressant_class" in _column_names("medication_definitions")

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
        # 0010 downgrade removes the by-session columns (schema.sql created
        # them eagerly on the 0001 upgrade — same ownership rule as 0009).
        cpap_cols = _column_names("cpap_sessions")
        assert "rdi_events" not in cpap_cols
        assert "leak_max" not in cpap_cols
        command.downgrade(cfg, "base")
        tables = _table_names()
        user_tables = tables - {"alembic_version"}
        assert not user_tables


class TestPharmacyImportRemoval:
    """0011 — drop pharmacy-import columns, purge stored pharmacy credentials.

    Data-safety contract (decision 3): dropping the import-only columns must
    never delete prescription rows — a previously-imported prescription
    survives 0011 as an ordinary manual-entry row. The only row deletions
    are settings keys for stored Walgreens/CapRx credentials; unrelated
    settings (e.g. resmed_*) must survive untouched.
    """

    def setup_method(self):
        _reset_db()

    @staticmethod
    def _insert_setting(key, value="x"):
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            cur.execute("INSERT INTO settings (key, value) VALUES (%s, %s)", (key, value))
        conn.commit()
        conn.close()

    @staticmethod
    def _insert_prescription(rx_number):
        # quantity is no longer part of the baseline schema (dropped by
        # 0012) — omit it here so this 0011-focused test still works on a
        # DB upgraded only to "0010".
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO prescriptions
                       (rx_number, medication_name, dose_mg, date_filled,
                        import_source, walgreens_rx_id)
                   VALUES (%s, 'Test Med', 1.0, NOW(), 'walgreens', 'W-123')""",
                (rx_number,),
            )
        conn.commit()
        conn.close()

    @staticmethod
    def _add_legacy_pharmacy_import_columns():
        """Simulate a pre-0011 production database.

        schema.sql (and therefore the 0001 baseline upgrade) no longer
        creates these columns, so a fresh "upgrade to 0010" scratch DB
        never has them — 0011's DROP COLUMN IF EXISTS would be a silent
        no-op against it. Add the columns back by hand, exactly as the
        old schema.sql/0001 did, so this test exercises 0011 actually
        dropping real columns on a database that has them.
        """
        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("""
                ALTER TABLE prescriptions
                    ADD COLUMN prescriber_name TEXT NOT NULL DEFAULT '',
                    ADD COLUMN ndc_code TEXT NOT NULL DEFAULT '',
                    ADD COLUMN rx_status TEXT NOT NULL DEFAULT '',
                    ADD COLUMN last_fill_date TIMESTAMPTZ,
                    ADD COLUMN import_source TEXT NOT NULL DEFAULT 'manual',
                    ADD COLUMN walgreens_rx_id TEXT,
                    ADD COLUMN directions TEXT NOT NULL DEFAULT '',
                    ADD COLUMN days_supply INTEGER,
                    ADD COLUMN patient_pay DOUBLE PRECISION,
                    ADD COLUMN plan_pay DOUBLE PRECISION,
                    ADD COLUMN dosage_form TEXT NOT NULL DEFAULT '',
                    ADD COLUMN drug_type TEXT NOT NULL DEFAULT ''
            """)
        conn.close()

    def test_upgrade_keeps_rows_drops_columns_purges_pharmacy_settings(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "0010")
        self._add_legacy_pharmacy_import_columns()
        self._insert_prescription("RX-KEEP-1")
        for key in ("walgreens_username", "walgreens_password",
                    "walgreens_security_answer", "caprx_username", "caprx_password"):
            self._insert_setting(key)
        for key in ("resmed_email", "resmed_password", "resmed_sync_time"):
            self._insert_setting(key)

        command.upgrade(cfg, "head")

        rx_cols = _column_names("prescriptions")
        assert rx_cols == {
            "rx_number", "medication_name", "dose_mg", "dose_description",
            "date_filled", "pharmacy_name", "notes",
        }, (
            f"unexpected prescriptions columns after upgrading to head "
            f"(0011 + 0012): {rx_cols}"
        )

        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            # No rows deleted — the previously-imported prescription survives
            # as an ordinary manual record.
            cur.execute("SELECT count(*) FROM prescriptions WHERE rx_number = 'RX-KEEP-1'")
            assert cur.fetchone()[0] == 1
            cur.execute("SELECT key FROM settings ORDER BY key")
            remaining = {row[0] for row in cur.fetchall()}
        conn.close()
        assert remaining == {"resmed_email", "resmed_password", "resmed_sync_time"}, (
            "settings purge should delete only walgreens_/caprx_ keys and leave "
            f"everything else (e.g. resmed_*) untouched; got {remaining}"
        )

    def test_downgrade_recreates_baseline_accurate_columns(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "head")
        command.downgrade(cfg, "0010")

        recreated = ("prescriber_name", "ndc_code", "rx_status", "last_fill_date",
                     "import_source", "walgreens_rx_id", "directions", "days_supply",
                     "patient_pay", "plan_pay", "dosage_form", "drug_type")
        rx_cols = _column_names("prescriptions")
        for col in recreated:
            assert col in rx_cols, f"downgrade did not recreate prescriptions.{col}"

        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        with conn.cursor() as cur:
            # Baseline defaults: bare-minimum insert should backfill the
            # recreated columns with the same values schema.sql/0001 used.
            cur.execute(
                """INSERT INTO prescriptions (rx_number, medication_name, dose_mg,
                       quantity, date_filled)
                   VALUES ('RX-DOWNGRADE', 'Med', 1.0, 1, NOW())"""
            )
            cur.execute(
                """SELECT prescriber_name, ndc_code, rx_status, import_source,
                          directions, dosage_form, drug_type, last_fill_date,
                          walgreens_rx_id, days_supply, patient_pay, plan_pay
                   FROM prescriptions WHERE rx_number = 'RX-DOWNGRADE'"""
            )
            (prescriber_name, ndc_code, rx_status, import_source, directions,
             dosage_form, drug_type, last_fill_date, walgreens_rx_id,
             days_supply, patient_pay, plan_pay) = cur.fetchone()

            assert (prescriber_name, ndc_code, rx_status, directions,
                    dosage_form, drug_type) == ("", "", "", "", "", ""), (
                "recreated TEXT columns should default to '' like baseline"
            )
            assert import_source == "manual", (
                "recreated import_source should default to 'manual' like baseline"
            )
            assert (last_fill_date, walgreens_rx_id, days_supply, patient_pay,
                    plan_pay) == (None, None, None, None, None)

            # Baseline declares prescriber_name/ndc_code/rx_status/import_source/
            # directions/dosage_form/drug_type NOT NULL — the downgrade must
            # recreate that constraint, not just the default.
            with pytest.raises(psycopg2.errors.NotNullViolation):
                with conn.cursor() as cur2:
                    cur2.execute(
                        "UPDATE prescriptions SET prescriber_name = NULL "
                        "WHERE rx_number = 'RX-DOWNGRADE'"
                    )
        conn.close()

        # Round trip stays clean: re-upgrading drops them again.
        command.upgrade(cfg, "head")
        assert "prescriber_name" not in _column_names("prescriptions")


class TestSupplyTrackingRemoval:
    """0012 — drop prescription supply-tracking columns.

    Data-safety contract (mirrors 0011): dropping the supply-only columns
    must never delete prescription rows — an existing prescription survives
    0012 as a plain descriptive record with the four supply-tracking
    columns gone.
    """

    def setup_method(self):
        _reset_db()

    @staticmethod
    def _insert_prescription(rx_number):
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO prescriptions
                       (rx_number, medication_name, dose_mg, quantity, date_filled)
                   VALUES (%s, 'Test Med', 1.0, 30, NOW())""",
                (rx_number,),
            )
        conn.commit()
        conn.close()

    @staticmethod
    def _add_legacy_supply_columns():
        """Simulate a pre-0012 production database.

        schema.sql (and therefore the 0001 baseline upgrade) no longer
        creates these columns, so a fresh "upgrade to 0011" scratch DB
        never has them — 0012's DROP COLUMN IF EXISTS would be a silent
        no-op against it. Add the columns back by hand, shape-compatible
        with the old schema; quantity gets a temporary default since the
        helper must succeed on tables with rows. This lets the test
        exercise 0012 actually dropping real columns on a database that
        has them.
        """
        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("""
                ALTER TABLE prescriptions
                    ADD COLUMN quantity INTEGER NOT NULL DEFAULT 0,
                    ADD COLUMN refills_remaining INTEGER NOT NULL DEFAULT 0,
                    ADD COLUMN estimated_run_out_date TIMESTAMPTZ,
                    ADD COLUMN daily_dose_count DOUBLE PRECISION
            """)
        conn.close()

    def test_upgrade_keeps_rows_drops_columns(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "0011")
        self._add_legacy_supply_columns()
        self._insert_prescription("RX-KEEP-1")

        command.upgrade(cfg, "head")

        rx_cols = _column_names("prescriptions")
        assert rx_cols == {
            "rx_number", "medication_name", "dose_mg", "dose_description",
            "date_filled", "pharmacy_name", "notes",
        }, f"unexpected prescriptions columns after 0012: {rx_cols}"

        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            # No rows deleted — the existing prescription survives as a
            # plain descriptive record.
            cur.execute("SELECT count(*) FROM prescriptions WHERE rx_number = 'RX-KEEP-1'")
            assert cur.fetchone()[0] == 1
        conn.close()

    def test_downgrade_recreates_quantity_not_null_no_default(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "head")
        command.downgrade(cfg, "0011")

        recreated = ("quantity", "refills_remaining", "estimated_run_out_date",
                     "daily_dose_count")
        rx_cols = _column_names("prescriptions")
        for col in recreated:
            assert col in rx_cols, f"downgrade did not recreate prescriptions.{col}"

        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(
                "SELECT column_default, is_nullable FROM information_schema.columns "
                "WHERE table_name = 'prescriptions' AND column_name = 'quantity'"
            )
            assert cur.fetchone() == (None, "NO"), (
                "recreated quantity column should be NOT NULL with no default, "
                "matching the baseline exactly"
            )

            # Behavioral confirmation of the NOT NULL constraint: an insert
            # that omits quantity (no default to fall back on) must fail.
            with pytest.raises(psycopg2.errors.NotNullViolation):
                with conn.cursor() as cur2:
                    cur2.execute(
                        """INSERT INTO prescriptions
                               (rx_number, medication_name, dose_mg, date_filled)
                           VALUES ('RX-NO-QUANTITY', 'Med', 1.0, NOW())"""
                    )
        conn.close()

        # Round trip stays clean: re-upgrading drops them again.
        command.upgrade(cfg, "head")
        assert "quantity" not in _column_names("prescriptions")


class TestMedicationCnsClassColumn:
    """0013 — add medication_definitions.cns_depressant_class.

    Additive nullable column carrying the app's explicit CNS-depressant
    classification (source of truth for dose-window monitoring). Data-safety
    contract: existing medication_definitions rows survive the upgrade with
    the new column NULL; downgrade drops only the column, never rows.
    """

    def setup_method(self):
        _reset_db()

    @staticmethod
    def _insert_med_def(name):
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO medication_definitions
                       (name, default_dose_mg, category, is_active)
                   VALUES (%s, 1.0, 'benzodiazepine', TRUE)""",
                (name,),
            )
        conn.commit()
        conn.close()

    @staticmethod
    def _drop_cns_class_column():
        """Simulate a pre-0013 production database.

        schema.sql (and therefore the 0001 baseline upgrade) now creates
        cns_depressant_class eagerly, so a fresh "upgrade to 0012" scratch
        DB already has it — 0013's ADD COLUMN IF NOT EXISTS would be a
        silent no-op against it (same ownership rule as 0011/0012's
        legacy-column helpers, in the opposite direction). Drop it by hand
        so the test exercises 0013 actually adding the column to a database
        that lacks it.
        """
        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(
                "ALTER TABLE medication_definitions DROP COLUMN cns_depressant_class"
            )
        conn.close()

    def test_upgrade_adds_column_keeps_rows(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "0012")
        self._drop_cns_class_column()
        self._insert_med_def("Test Benzo 1mg")

        command.upgrade(cfg, "head")

        assert "cns_depressant_class" in _column_names("medication_definitions")
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            # No rows deleted; pre-existing rows read back NULL (unclassified)
            # rather than any fabricated class.
            cur.execute(
                "SELECT cns_depressant_class FROM medication_definitions "
                "WHERE name = 'Test Benzo 1mg'"
            )
            row = cur.fetchone()
            assert row is not None, "existing medication_definitions row must survive 0013"
            assert row[0] is None
        conn.close()

    def test_downgrade_removes_column_keeps_rows(self):
        cfg = _alembic_cfg()
        command.upgrade(cfg, "head")
        self._insert_med_def("Test Benzo 1mg")

        command.downgrade(cfg, "0012")

        assert "cns_depressant_class" not in _column_names("medication_definitions")
        conn = psycopg2.connect(DATABASE_URL)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM medication_definitions WHERE name = 'Test Benzo 1mg'"
            )
            assert cur.fetchone()[0] == 1
        conn.close()

        # Round trip stays clean: re-upgrading adds it again.
        command.upgrade(cfg, "head")
        assert "cns_depressant_class" in _column_names("medication_definitions")


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
