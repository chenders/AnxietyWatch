import os
import pytest
import psycopg2
from resmed_sync import upsert_sessions, should_run_now


@pytest.fixture
def db():
    """Connect to test database."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        pytest.skip("DATABASE_URL not set")
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    yield conn
    conn.rollback()
    conn.close()


@pytest.fixture
def clean_cpap(db):
    """Ensure cpap_sessions is empty for this test."""
    cur = db.cursor()
    cur.execute("DELETE FROM cpap_sessions")
    db.commit()
    yield db
    cur.execute("DELETE FROM cpap_sessions")
    db.commit()


def test_insert_new_session(clean_cpap):
    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 1
    cur = clean_cpap.cursor()
    cur.execute("SELECT import_source FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == "resmed_cloud"


def test_skip_existing_sd_card(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute(
        "INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
        "VALUES ('2026-03-20', 1.0, 400, 'sd_card')"
    )
    clean_cpap.commit()
    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 0
    cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == 1.0


def test_update_existing_cloud(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute(
        "INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
        "VALUES ('2026-03-20', 1.0, 400, 'resmed_cloud')"
    )
    clean_cpap.commit()
    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 1
    cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == 2.5


def test_multiple_sessions(clean_cpap):
    sessions = [
        {"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
         "leak_percentile": None, "mean_pressure": None},
        {"date": "2026-03-21", "ahi": 1.8, "total_usage_minutes": 390,
         "leak_percentile": 15.0, "mean_pressure": None},
    ]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 2


# Schedule tests (no DB needed)

def test_should_run_now_matching_hour():
    assert should_run_now("14", 14) is True
    assert should_run_now("14:30", 14) is True


def test_should_run_now_non_matching_hour():
    assert should_run_now("14", 15) is False
    assert should_run_now("08:00", 14) is False


def test_should_run_now_invalid():
    assert should_run_now("", 14) is False
    assert should_run_now(None, 14) is False


def test_should_run_now_default_2pm_pacific():
    """Default sync time is 21:00 UTC (2:00 PM Pacific)."""
    assert should_run_now("21", 21) is True
    assert should_run_now("21:00", 21) is True
