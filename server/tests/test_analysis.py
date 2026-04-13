"""Tests for the AI analysis engine."""

import hashlib
import json
import os
import sys
from datetime import date

import psycopg2
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

TEST_API_KEY = "test-key-for-pytest-12345678"
TEST_API_KEY_HASH = hashlib.sha256(TEST_API_KEY.encode()).hexdigest()


@pytest.fixture(scope="session")
def _init_db():
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


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.fixture(autouse=True)
def _clean_tables(app):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "TRUNCATE anxiety_entries, health_snapshots, medication_definitions, "
            "medication_doses, cpap_sessions, barometric_readings, correlations, "
            "analyses, api_keys, sync_log RESTART IDENTITY CASCADE"
        )
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) "
            "VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


def _insert_test_data(app):
    """Insert test data across multiple tables for a 3-day range."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        for i in range(3):
            d = f"2026-01-{i + 10:02d}"
            cur.execute(
                "INSERT INTO anxiety_entries (timestamp, severity, notes, tags) "
                "VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
                (f"{d} 12:00:00+00", 5 + i, "test note", "[]"),
            )
            cur.execute(
                "INSERT INTO health_snapshots (date, hrv_avg, resting_hr, steps) "
                "VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
                (d, 45.0 + i, 65.0 - i, 5000 + i * 1000),
            )
            cur.execute(
                "INSERT INTO cpap_sessions (date, ahi, total_usage_minutes) "
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (d, 2.5 + i * 0.5, 360 + i * 30),
            )
        cur.execute(
            "INSERT INTO medication_definitions (name, default_dose_mg, category) "
            "VALUES ('TestMed', 1.0, 'test') ON CONFLICT DO NOTHING"
        )
        cur.execute(
            "INSERT INTO medication_doses (timestamp, medication_name, dose_mg) "
            "VALUES ('2026-01-10 08:00:00+00', 'TestMed', 1.0) ON CONFLICT DO NOTHING"
        )
        db.commit()


def test_gather_analysis_data(app):
    """gather_analysis_data returns all data sources for date range."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import gather_analysis_data
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        data = gather_analysis_data(cur, date(2026, 1, 10), date(2026, 1, 12))

    assert len(data["anxiety_entries"]) == 3
    assert len(data["health_snapshots"]) == 3
    assert len(data["cpap_sessions"]) == 3
    assert len(data["medication_doses"]) == 1
    assert data["medication_doses"][0]["medication_name"] == "TestMed"


def test_gather_analysis_data_filters_by_date(app):
    """gather_analysis_data only returns data within the date range."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import gather_analysis_data
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        data = gather_analysis_data(cur, date(2026, 1, 10), date(2026, 1, 10))

    assert len(data["anxiety_entries"]) == 1
    assert len(data["health_snapshots"]) == 1
    assert len(data["cpap_sessions"]) == 1


def test_gather_analysis_data_empty_range(app):
    """gather_analysis_data returns empty lists for range with no data."""
    with app.app_context():
        from analysis import gather_analysis_data
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        data = gather_analysis_data(cur, date(2099, 1, 1), date(2099, 1, 31))

    assert data["anxiety_entries"] == []
    assert data["health_snapshots"] == []
    assert data["cpap_sessions"] == []
    assert data["medication_doses"] == []


def test_build_prompt(app):
    """build_prompt returns system and user messages with all data."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import gather_analysis_data, build_prompt
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        data = gather_analysis_data(cur, date(2026, 1, 10), date(2026, 1, 12))
        system, user_msg = build_prompt(data, date(2026, 1, 10), date(2026, 1, 12))

    assert "clinical data analyst" in system.lower()
    assert "anxiety_entries" in user_msg
    assert "health_snapshots" in user_msg
    assert "2026-01-10" in user_msg
    assert "json" in system.lower() or "JSON" in system


def test_build_prompt_includes_output_schema(app):
    """build_prompt system message describes the expected insight structure."""
    with app.app_context():
        from analysis import build_prompt
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )

    assert "confidence" in system
    assert "severity" in system
    assert "category" in system
    assert "supporting_data" in system
