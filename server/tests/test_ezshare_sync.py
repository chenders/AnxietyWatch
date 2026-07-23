import os
from unittest.mock import patch

import psycopg2
import pytest

import ezshare_sync
from ezshare_sync import upsert_ezshare_sessions, EZSHARE_SOURCE


@pytest.fixture(scope="session")
def _init_db():
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        pytest.skip("DATABASE_URL not set")
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    with open(os.path.join(os.path.dirname(__file__), "..", "schema.sql")) as f:
        conn.cursor().execute(f.read())
    conn.close()


@pytest.fixture
def db(_init_db):
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    conn.autocommit = False
    yield conn
    conn.rollback()
    conn.close()


@pytest.fixture
def clean_cpap(db):
    def _clean():
        cur = db.cursor()
        cur.execute("DELETE FROM cpap_sessions")
        cur.execute("DELETE FROM settings WHERE key LIKE 'ezshare_%'")
        cur.execute("DELETE FROM sync_log WHERE sync_type = 'ezshare'")
        db.commit()
    _clean()
    yield db
    _clean()


def _session(d, ahi=3.0):
    return {"date": d, "ahi": ahi, "total_usage_minutes": 420,
            "obstructive_events": 1, "central_events": 0, "hypopnea_events": 2,
            "rdi_events": None, "rera_events": None,
            "pressure_min": None, "pressure_max": None, "pressure_mean": 9.0,
            "pressure_95th": None, "leak_avg": None, "leak_max": None,
            "leak_rate_95th": 12.0, "spo2_avg": None, "spo2_min": None,
            "pulse_avg": None}


def test_inserts_with_ezshare_source(clean_cpap):
    assert upsert_ezshare_sessions(clean_cpap, [_session("2026-01-15")]) == 1
    cur = clean_cpap.cursor()
    cur.execute("SELECT import_source FROM cpap_sessions WHERE date='2026-01-15'")
    assert cur.fetchone()[0] == EZSHARE_SOURCE


def test_overwrites_resmed_cloud(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute("INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
                "VALUES ('2026-01-15', 1.0, 400, 'resmed_cloud')")
    clean_cpap.commit()
    assert upsert_ezshare_sessions(clean_cpap, [_session("2026-01-15", ahi=5.5)]) == 1
    cur.execute("SELECT ahi, import_source FROM cpap_sessions WHERE date='2026-01-15'")
    ahi, src = cur.fetchone()
    assert abs(ahi - 5.5) < 0.01 and src == EZSHARE_SOURCE


def test_skips_manual_sd_card(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute("INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
                "VALUES ('2026-01-15', 2.0, 401, 'sd_card')")
    clean_cpap.commit()
    assert upsert_ezshare_sessions(clean_cpap, [_session("2026-01-15", ahi=8.0)]) == 0
    cur.execute("SELECT ahi, import_source FROM cpap_sessions WHERE date='2026-01-15'")
    ahi, src = cur.fetchone()
    assert abs(ahi - 2.0) < 0.01 and src == "sd_card"


def test_idempotent_rerun(clean_cpap):
    upsert_ezshare_sessions(clean_cpap, [_session("2026-01-15")])
    upsert_ezshare_sessions(clean_cpap, [_session("2026-01-15")])
    cur = clean_cpap.cursor()
    cur.execute("SELECT COUNT(*) FROM cpap_sessions WHERE date='2026-01-15'")
    assert cur.fetchone()[0] == 1


def test_main_unreachable_is_noop(clean_cpap):
    with patch("ezshare_sync.EzShareClient") as C:
        C.return_value.version.side_effect = ezshare_sync.EzShareUnreachable("down")
        assert ezshare_sync.main([]) == 0
    cur = clean_cpap.cursor()
    cur.execute("SELECT value FROM settings WHERE key='ezshare_last_status'")
    assert cur.fetchone()[0] == "unreachable"


def test_main_ingests_parsed_sessions(clean_cpap):
    # Mock the client (return STR bytes) and the parser (return one session).
    with patch("ezshare_sync.EzShareClient") as C, \
         patch("ezshare_sync.parse_str_edf", return_value=[_session("2026-01-16", ahi=4.4)]):
        inst = C.return_value
        inst.version.return_value = "2.0.7"
        inst.download_str_edf.return_value = b"0       edf-bytes"
        assert ezshare_sync.main([]) == 0
    cur = clean_cpap.cursor()
    cur.execute("SELECT ahi, import_source FROM cpap_sessions WHERE date='2026-01-16'")
    ahi, src = cur.fetchone()
    assert abs(ahi - 4.4) < 0.01 and src == EZSHARE_SOURCE
    cur.execute("SELECT value FROM settings WHERE key='ezshare_last_status'")
    assert "ok:" in cur.fetchone()[0]
