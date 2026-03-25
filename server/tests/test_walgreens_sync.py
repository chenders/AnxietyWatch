"""Tests for the Walgreens prescription sync script."""

import os
import pytest
import psycopg2
from walgreens_sync import upsert_prescriptions, should_run_now


@pytest.fixture(scope="session")
def _init_db():
    """Create tables once per test session."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        pytest.skip("DATABASE_URL not set")
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()
    schema_path = os.path.join(os.path.dirname(__file__), "..", "schema.sql")
    with open(schema_path) as f:
        cur.execute(f.read())
    # Run migrations for new columns
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS prescriber_name TEXT NOT NULL DEFAULT ''")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS ndc_code TEXT NOT NULL DEFAULT ''")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS rx_status TEXT NOT NULL DEFAULT ''")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS last_fill_date TIMESTAMPTZ")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS import_source TEXT NOT NULL DEFAULT 'manual'")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS walgreens_rx_id TEXT")
    cur.execute("ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS directions TEXT NOT NULL DEFAULT ''")
    conn.close()


@pytest.fixture
def db(_init_db):
    """Connect to test database (schema guaranteed initialized)."""
    dsn = os.environ.get("DATABASE_URL")
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    yield conn
    conn.rollback()
    conn.close()


@pytest.fixture
def clean_rx(db):
    """Ensure prescriptions is empty for this test."""
    cur = db.cursor()
    cur.execute("DELETE FROM prescriptions")
    db.commit()
    yield db
    cur.execute("DELETE FROM prescriptions")
    db.commit()


SAMPLE_RX = {
    "rx_number": "2618630-03890",
    "medication_name": "Clonazepam 1mg Tablets",
    "dose_mg": 1.0,
    "dose_description": "1mg",
    "quantity": 60,
    "refills_remaining": 0,
    "date_filled": "12/31/2025",
    "pharmacy_name": "Walgreens",
    "prescriber_name": "Robert Geistwhite",
    "ndc_code": "00093321205",
    "rx_status": "Retail Pickup",
    "directions": "",
    "import_source": "walgreens",
    "walgreens_rx_id": "2618630-03890",
}


def test_insert_new_prescription(clean_rx):
    count = upsert_prescriptions(clean_rx, [SAMPLE_RX])
    assert count == 1
    cur = clean_rx.cursor()
    cur.execute("SELECT import_source, medication_name FROM prescriptions WHERE rx_number = %s",
                (SAMPLE_RX["rx_number"],))
    row = cur.fetchone()
    assert row[0] == "walgreens"
    assert row[1] == "Clonazepam 1mg Tablets"


def test_skip_existing_manual(clean_rx):
    cur = clean_rx.cursor()
    cur.execute(
        "INSERT INTO prescriptions (rx_number, medication_name, dose_mg, quantity, "
        "date_filled, import_source) VALUES (%s, %s, %s, %s, %s, 'manual')",
        ("2618630-03890", "Clonazepam 1mg", 1.0, 30, "2025-12-01"),
    )
    clean_rx.commit()

    count = upsert_prescriptions(clean_rx, [SAMPLE_RX])
    assert count == 0
    # Verify the manual data was not overwritten
    cur.execute("SELECT quantity FROM prescriptions WHERE rx_number = %s",
                (SAMPLE_RX["rx_number"],))
    assert cur.fetchone()[0] == 30


def test_update_existing_walgreens(clean_rx):
    cur = clean_rx.cursor()
    cur.execute(
        "INSERT INTO prescriptions (rx_number, medication_name, dose_mg, quantity, "
        "date_filled, import_source) VALUES (%s, %s, %s, %s, %s, 'walgreens')",
        ("2618630-03890", "Clonazepam 1mg Tablets", 1.0, 30, "2025-12-01"),
    )
    clean_rx.commit()

    count = upsert_prescriptions(clean_rx, [SAMPLE_RX])
    assert count == 1
    cur.execute("SELECT quantity FROM prescriptions WHERE rx_number = %s",
                (SAMPLE_RX["rx_number"],))
    assert cur.fetchone()[0] == 60


def test_multiple_prescriptions(clean_rx):
    rx2 = {**SAMPLE_RX, "rx_number": "9999999-99999", "medication_name": "Test Drug 50mg"}
    count = upsert_prescriptions(clean_rx, [SAMPLE_RX, rx2])
    assert count == 2


def test_empty_list(clean_rx):
    count = upsert_prescriptions(clean_rx, [])
    assert count == 0


# ---------------------------------------------------------------------------
# should_run_now tests
# ---------------------------------------------------------------------------

def test_should_run_now_match():
    assert should_run_now("21", 21) is True


def test_should_run_now_match_hhmm():
    assert should_run_now("21:00", 21) is True


def test_should_run_now_no_match():
    assert should_run_now("21", 15) is False


def test_should_run_now_none():
    assert should_run_now(None, 21) is False


def test_should_run_now_empty():
    assert should_run_now("", 21) is False


def test_should_run_now_invalid():
    assert should_run_now("not-a-time", 21) is False
