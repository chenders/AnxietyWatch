"""Tests for the Walgreens prescription sync script."""

import os
from datetime import date, timedelta
from urllib.parse import urlparse

import pytest
import psycopg2
from walgreens_sync import (
    upsert_prescriptions,
    should_run_now,
    compute_lookback_start,
    DEFAULT_LOOKBACK_DAYS,
    FIRST_SYNC_LOOKBACK_DAYS,
    LAST_SYNC_OVERLAP_DAYS,
)

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

# Ensure env.py sees the resolved test URL.
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


@pytest.fixture
def db(_init_db):
    """Connect to test database (schema guaranteed initialized)."""
    conn = psycopg2.connect(DATABASE_URL)
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
    "rx_number": "9999999-00001",
    "medication_name": "Clonazepam 1mg Tablets",
    "dose_mg": 1.0,
    "dose_description": "1mg",
    "quantity": 60,
    "refills_remaining": 0,
    "date_filled": "2025-12-31T00:00:00+00:00",
    "pharmacy_name": "Walgreens",
    "prescriber_name": "Jane Smith MD",
    "ndc_code": "00000-0000-00",
    "rx_status": "Retail Pickup",
    "directions": "",
    "import_source": "walgreens",
    "walgreens_rx_id": "9999999-00001",
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
        ("9999999-00001", "Clonazepam 1mg", 1.0, 30, "2025-12-01"),
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
        ("9999999-00001", "Clonazepam 1mg Tablets", 1.0, 30, "2025-12-01"),
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


# ---------------------------------------------------------------------------
# compute_lookback_start tests (F-054)
# ---------------------------------------------------------------------------

TODAY = date(2026, 7, 8)


def test_lookback_no_prior_sync_uses_two_year_default():
    """First sync goes back the full 2 years Walgreens allows."""
    start = compute_lookback_start(TODAY, None)
    assert start == TODAY - timedelta(days=FIRST_SYNC_LOOKBACK_DAYS)


def test_lookback_recent_sync_uses_90_day_floor():
    """A sync that succeeded last week keeps the normal 90-day floor."""
    last_success = TODAY - timedelta(days=7)
    start = compute_lookback_start(TODAY, last_success)
    assert start == TODAY - timedelta(days=DEFAULT_LOOKBACK_DAYS)


def test_lookback_widens_past_90_days_after_long_outage():
    """An outage longer than 90 days must widen the window back to the last
    success (minus overlap), or fills dispensed in the gap are permanently
    lost — the F-054 failure mode."""
    last_success = TODAY - timedelta(days=200)
    start = compute_lookback_start(TODAY, last_success)
    assert start == last_success - timedelta(days=LAST_SYNC_OVERLAP_DAYS)
    # The widened window fully covers the gap since the last success.
    assert start < last_success


def test_lookback_exactly_90_days_gets_overlap():
    """At exactly 90 days since success, the overlap wins (min of the two)."""
    last_success = TODAY - timedelta(days=DEFAULT_LOOKBACK_DAYS)
    start = compute_lookback_start(TODAY, last_success)
    assert start == last_success - timedelta(days=LAST_SYNC_OVERLAP_DAYS)


def test_lookback_capped_at_walgreens_two_year_max():
    """Walgreens only serves 2 years of history — never ask for more."""
    last_success = TODAY - timedelta(days=900)
    start = compute_lookback_start(TODAY, last_success)
    assert start == TODAY - timedelta(days=FIRST_SYNC_LOOKBACK_DAYS)
