"""Tests for the health data formatting migration."""
import os
import sys
from datetime import date

import psycopg2
import psycopg2.extras
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from server import create_app  # noqa: E402

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get(
        "DATABASE_URL",
        "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test",
    ),
)


@pytest.fixture(scope="session")
def _init_db():
    """Create tables once per test session."""
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    cur = conn.cursor()
    schema_path = os.path.join(os.path.dirname(__file__), "..", "schema.sql")
    with open(schema_path) as f:
        cur.execute(f.read())
    conn.close()


@pytest.fixture()
def app(_init_db):
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    yield app


@pytest.fixture(autouse=True)
def _clean_tables(app):
    """Truncate health_snapshots before each test."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("TRUNCATE health_snapshots RESTART IDENTITY CASCADE")
        db.commit()
    yield


def test_spo2_scaling(app):
    """Migration scales SpO2 from 0-1 to 0-100."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots (date, spo2_avg) VALUES (%s, %s)",
            (date(2026, 1, 10), 0.96),
        )
        db.commit()

        from migrations.fix_2026_04_17_health_data_formatting import run_migration
        run_migration(DATABASE_URL)

        cur.execute("SELECT spo2_avg FROM health_snapshots WHERE date = %s", (date(2026, 1, 10),))
        assert abs(cur.fetchone()[0] - 96.0) < 0.01


def test_spo2_already_correct_not_touched(app):
    """Migration doesn't touch SpO2 values already on 0-100 scale."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots (date, spo2_avg) VALUES (%s, %s)",
            (date(2026, 1, 10), 97.5),
        )
        db.commit()

        from migrations.fix_2026_04_17_health_data_formatting import run_migration
        run_migration(DATABASE_URL)

        cur.execute("SELECT spo2_avg FROM health_snapshots WHERE date = %s", (date(2026, 1, 10),))
        assert cur.fetchone()[0] == 97.5


def test_skin_temp_moved_to_wrist(app):
    """Migration moves absolute temps (>5) to skin_temp_wrist."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots (date, skin_temp_deviation) VALUES (%s, %s)",
            (date(2026, 1, 10), 35.5),
        )
        db.commit()

        from migrations.fix_2026_04_17_health_data_formatting import run_migration
        run_migration(DATABASE_URL)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT skin_temp_deviation, skin_temp_wrist FROM health_snapshots WHERE date = %s",
            (date(2026, 1, 10),),
        )
        row = cur.fetchone()
        assert row["skin_temp_deviation"] is None
        assert row["skin_temp_wrist"] == 35.5


def test_skin_temp_real_deviation_not_moved(app):
    """Migration leaves real deviation values (<=5) alone."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots (date, skin_temp_deviation) VALUES (%s, %s)",
            (date(2026, 1, 10), 0.3),
        )
        db.commit()

        from migrations.fix_2026_04_17_health_data_formatting import run_migration
        run_migration(DATABASE_URL)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT skin_temp_deviation, skin_temp_wrist FROM health_snapshots WHERE date = %s",
            (date(2026, 1, 10),),
        )
        row = cur.fetchone()
        assert row["skin_temp_deviation"] == 0.3
        assert row["skin_temp_wrist"] is None


def test_sleep_duration_adjusted(app):
    """Migration adjusts sleep_duration_min when stages exceed it."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots "
            "(date, sleep_duration_min, sleep_deep_min, sleep_rem_min, sleep_core_min) "
            "VALUES (%s, %s, %s, %s, %s)",
            (date(2026, 1, 10), 420, 200, 150, 200),  # stages sum to 550 > 420
        )
        db.commit()

        from migrations.fix_2026_04_17_health_data_formatting import run_migration
        run_migration(DATABASE_URL)

        cur.execute(
            "SELECT sleep_duration_min FROM health_snapshots WHERE date = %s",
            (date(2026, 1, 10),),
        )
        assert cur.fetchone()[0] == 550  # adjusted to stage sum
