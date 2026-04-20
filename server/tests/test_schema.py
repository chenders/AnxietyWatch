"""Tests for schema changes: settings table and nullable CPAP columns."""

import os
from urllib.parse import urlparse

import psycopg2
import pytest

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get("DATABASE_URL", "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test"),
)

# Guard against accidentally running destructive tests on a non-test database.
_db_name = urlparse(DATABASE_URL).path.rsplit("/", 1)[-1]
if "test" not in _db_name:
    raise RuntimeError(
        f"Refusing to run destructive schema tests against '{_db_name}'. "
        "DATABASE_URL must point to a database whose name contains 'test'."
    )

# Ensure env.py sees the resolved test URL (it reads DATABASE_URL env var
# first). Set once at module level so the intent is explicit.
os.environ["DATABASE_URL"] = DATABASE_URL


@pytest.fixture(scope="session")
def _init_db():
    """Apply Alembic migrations once per test session."""
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("DROP SCHEMA IF EXISTS public CASCADE")
        cur.execute("CREATE SCHEMA public")
    conn.close()

    from alembic.config import Config
    from alembic import command

    alembic_ini = os.path.join(os.path.dirname(__file__), "..", "alembic.ini")
    cfg = Config(alembic_ini)
    cfg.set_main_option("sqlalchemy.url", DATABASE_URL)
    command.upgrade(cfg, "head")


@pytest.fixture()
def db_conn(_init_db):
    """Provide a connection and clean relevant tables before each test."""
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("DELETE FROM settings")
    cur.execute("DELETE FROM cpap_sessions")
    yield conn
    conn.close()


# ---------------------------------------------------------------------------
# Settings table
# ---------------------------------------------------------------------------


def test_settings_table_crud(db_conn):
    """Insert a setting, read it back, update it, verify upsert works."""
    cur = db_conn.cursor()

    # Insert
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s)",
        ("resmed_token", "abc123"),
    )

    # Read
    cur.execute("SELECT key, value FROM settings WHERE key = %s", ("resmed_token",))
    row = cur.fetchone()
    assert row is not None
    assert row[0] == "resmed_token"
    assert row[1] == "abc123"

    # Update
    cur.execute(
        "UPDATE settings SET value = %s, updated_at = NOW() WHERE key = %s",
        ("xyz789", "resmed_token"),
    )
    cur.execute("SELECT value FROM settings WHERE key = %s", ("resmed_token",))
    row = cur.fetchone()
    assert row[0] == "xyz789"


def test_settings_upsert(db_conn):
    """Insert a setting, then upsert with the same key — value should update."""
    cur = db_conn.cursor()

    # Initial insert
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s)",
        ("refresh_token", "old_value"),
    )
    cur.execute("SELECT value FROM settings WHERE key = %s", ("refresh_token",))
    assert cur.fetchone()[0] == "old_value"

    # Upsert (ON CONFLICT)
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        ("refresh_token", "new_value"),
    )
    cur.execute("SELECT value FROM settings WHERE key = %s", ("refresh_token",))
    assert cur.fetchone()[0] == "new_value"

    # Verify only one row exists for that key
    cur.execute("SELECT COUNT(*) FROM settings WHERE key = %s", ("refresh_token",))
    assert cur.fetchone()[0] == 1


# ---------------------------------------------------------------------------
# CPAP session nullable columns
# ---------------------------------------------------------------------------


def test_cpap_session_nullable_pressure(db_conn):
    """Insert a CPAP session with NULL pressure and leak columns (e.g. myAir source)."""
    cur = db_conn.cursor()

    cur.execute(
        "INSERT INTO cpap_sessions "
        "(date, ahi, total_usage_minutes, leak_rate_95th, pressure_min, pressure_max, pressure_mean, "
        "obstructive_events, central_events, hypopnea_events, import_source) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        ("2025-03-20", 2.5, 420, None, None, None, None, 5, 2, 3, "myair"),
    )

    cur.execute(
        "SELECT pressure_min, pressure_max, pressure_mean, leak_rate_95th FROM cpap_sessions WHERE date = %s",
        ("2025-03-20",),
    )
    row = cur.fetchone()
    assert row[0] is None  # pressure_min
    assert row[1] is None  # pressure_max
    assert row[2] is None  # pressure_mean
    assert row[3] is None  # leak_rate_95th


def test_cpap_session_with_full_data(db_conn):
    """Insert a CPAP session with all fields populated (SD card import path)."""
    cur = db_conn.cursor()

    cur.execute(
        "INSERT INTO cpap_sessions "
        "(date, ahi, total_usage_minutes, leak_rate_95th, pressure_min, pressure_max, pressure_mean, "
        "obstructive_events, central_events, hypopnea_events, import_source) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        ("2025-03-21", 1.8, 450, 5.1, 6.0, 12.0, 9.5, 3, 1, 2, "sd_card"),
    )

    cur.execute(
        "SELECT ahi, total_usage_minutes, leak_rate_95th, pressure_min, pressure_max, pressure_mean, "
        "obstructive_events, central_events, hypopnea_events, import_source "
        "FROM cpap_sessions WHERE date = %s",
        ("2025-03-21",),
    )
    row = cur.fetchone()
    assert row[0] == 1.8            # ahi
    assert row[1] == 450            # total_usage_minutes
    assert row[2] == 5.1            # leak_rate_95th
    assert row[3] == 6.0            # pressure_min
    assert row[4] == 12.0           # pressure_max
    assert row[5] == 9.5            # pressure_mean
    assert row[6] == 3              # obstructive_events
    assert row[7] == 1              # central_events
    assert row[8] == 2              # hypopnea_events
    assert row[9] == "sd_card"      # import_source
