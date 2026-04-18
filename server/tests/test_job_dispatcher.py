"""Tests for the analysis job dispatcher."""

import hashlib
import os
import sys
from datetime import date
from unittest.mock import patch

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


@pytest.fixture(autouse=True)
def _clean_tables(app):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "TRUNCATE anxiety_entries, health_snapshots, medication_definitions, "
            "medication_doses, cpap_sessions, barometric_readings, correlations, "
            "analyses, api_keys, sync_log, therapy_sessions, settings, "
            "patient_profile, psychiatrist_profile, conflicts, analysis_jobs "
            "RESTART IDENTITY CASCADE"
        )
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) "
            "VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


def _create_test_analysis(app):
    """Create a minimal analysis row and return its ID."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO analyses (date_from, date_to, status, model) "
            "VALUES ('2026-01-10', '2026-01-12', 'pending', 'claude-opus-4-7') RETURNING id"
        )
        analysis_id = cur.fetchone()[0]
        db.commit()
    return analysis_id


def _create_test_conflict(app):
    """Create an active conflict and return its ID."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective, psychiatrist_perspective) "
            "VALUES ('Test conflict', 'Patient view', 'Psychiatrist view') RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()
    return conflict_id


def test_create_jobs_without_conflict(app):
    """create_analysis_jobs without active conflict creates only health_analysis job."""
    analysis_id = _create_test_analysis(app)
    with app.app_context():
        db = app.get_db()
        from job_dispatcher import create_analysis_jobs
        create_analysis_jobs(db, analysis_id)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM analysis_jobs WHERE analysis_id = %s ORDER BY id",
            (analysis_id,),
        )
        jobs = cur.fetchall()

    assert len(jobs) == 1
    assert jobs[0]["job_type"] == "health_analysis"
    assert jobs[0]["depends_on"] is None or jobs[0]["depends_on"] == []


def test_create_jobs_with_conflict(app):
    """create_analysis_jobs with active conflict creates 6 jobs with correct dependencies."""
    analysis_id = _create_test_analysis(app)
    conflict_id = _create_test_conflict(app)
    with app.app_context():
        db = app.get_db()
        from job_dispatcher import create_analysis_jobs
        create_analysis_jobs(db, analysis_id)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM analysis_jobs WHERE analysis_id = %s ORDER BY id",
            (analysis_id,),
        )
        jobs = cur.fetchall()

    assert len(jobs) == 6
    job_types = [j["job_type"] for j in jobs]
    assert "health_analysis" in job_types
    assert "patient_validity" in job_types
    assert "psychiatrist_validity" in job_types
    assert "patient_criticism" in job_types
    assert "psychiatrist_criticism" in job_types
    assert "conflict_synthesis" in job_types

    # health_analysis has no dependencies
    health_job = [j for j in jobs if j["job_type"] == "health_analysis"][0]
    assert health_job["depends_on"] is None or health_job["depends_on"] == []

    # Research jobs depend on health_analysis
    for jt in ["patient_validity", "psychiatrist_validity", "patient_criticism", "psychiatrist_criticism"]:
        job = [j for j in jobs if j["job_type"] == jt][0]
        assert health_job["id"] in job["depends_on"]

    # Synthesis depends on all 4 research jobs
    synthesis_job = [j for j in jobs if j["job_type"] == "conflict_synthesis"][0]
    research_ids = [j["id"] for j in jobs if j["job_type"] not in ("health_analysis", "conflict_synthesis")]
    for rid in research_ids:
        assert rid in synthesis_job["depends_on"]

    # All conflict jobs reference the conflict
    for j in jobs:
        if j["job_type"] != "health_analysis":
            assert j["conflict_id"] == conflict_id


def test_find_ready_jobs(app):
    """find_ready_jobs returns pending jobs whose dependencies are all completed."""
    analysis_id = _create_test_analysis(app)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        # Create 2 jobs: health (no deps) and validity (depends on health)
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'health_analysis', '{}', 'pending', 'claude-opus-4-7') RETURNING id",
            (analysis_id,),
        )
        health_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'patient_validity', %s, 'pending', 'claude-opus-4-7')",
            (analysis_id, [health_id]),
        )
        db.commit()

        from job_dispatcher import find_ready_jobs
        ready = find_ready_jobs(db, analysis_id)
    # Only health_analysis should be ready (validity depends on it)
    assert len(ready) == 1
    assert ready[0]["job_type"] == "health_analysis"


def test_find_ready_jobs_after_dependency_completed(app):
    """find_ready_jobs returns dependent job after its dependency completes."""
    analysis_id = _create_test_analysis(app)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'health_analysis', '{}', 'completed', 'claude-opus-4-7') RETURNING id",
            (analysis_id,),
        )
        health_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'patient_validity', %s, 'pending', 'claude-opus-4-7')",
            (analysis_id, [health_id]),
        )
        db.commit()

        from job_dispatcher import find_ready_jobs
        ready = find_ready_jobs(db, analysis_id)
    assert len(ready) == 1
    assert ready[0]["job_type"] == "patient_validity"


def test_cascade_failures(app):
    """cascade_failures marks dependent jobs as failed."""
    analysis_id = _create_test_analysis(app)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'health_analysis', '{}', 'failed', 'claude-opus-4-7') RETURNING id",
            (analysis_id,),
        )
        health_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'patient_validity', %s, 'pending', 'claude-opus-4-7') RETURNING id",
            (analysis_id, [health_id]),
        )
        validity_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
            "VALUES (%s, 'conflict_synthesis', %s, 'pending', 'claude-opus-4-7')",
            (analysis_id, [validity_id]),
        )
        db.commit()

        from job_dispatcher import cascade_failures
        cascade_failures(db, health_id)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT job_type, status, error_message FROM analysis_jobs "
            "WHERE analysis_id = %s ORDER BY id",
            (analysis_id,),
        )
        jobs = cur.fetchall()

    # All downstream jobs should be failed
    assert jobs[1]["status"] == "failed"
    assert f"Dependency job {health_id} failed" in jobs[1]["error_message"]
    assert jobs[2]["status"] == "failed"
    assert f"Dependency job {validity_id} failed" in jobs[2]["error_message"]


@patch("job_dispatcher.dispatch_analysis")
def test_start_analysis_creates_jobs(mock_dispatch, app):
    """start_analysis creates analysis_jobs rows via the dispatcher."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        # Insert test data so analysis has something to work with
        cur.execute(
            "INSERT INTO anxiety_entries (timestamp, severity, notes, tags) "
            "VALUES ('2026-01-10 12:00:00+00', 5, 'test', '[]')"
        )
        db.commit()

        from analysis import start_analysis
        analysis_id = start_analysis(db, date(2026, 1, 10), date(2026, 1, 10),
                                     database_url=DATABASE_URL)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM analysis_jobs WHERE analysis_id = %s",
            (analysis_id,),
        )
        jobs = cur.fetchall()

    assert len(jobs) >= 1  # at least health_analysis
    assert any(j["job_type"] == "health_analysis" for j in jobs)
    mock_dispatch.assert_called_once()


@patch("job_dispatcher.dispatch_analysis")
def test_start_analysis_with_conflict_creates_6_jobs(mock_dispatch, app):
    """start_analysis with active conflict creates all 6 job types."""
    _create_test_conflict(app)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO anxiety_entries (timestamp, severity, notes, tags) "
            "VALUES ('2026-01-10 12:00:00+00', 5, 'test', '[]')"
        )
        db.commit()

        from analysis import start_analysis
        analysis_id = start_analysis(db, date(2026, 1, 10), date(2026, 1, 10),
                                     database_url=DATABASE_URL)

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT job_type FROM analysis_jobs WHERE analysis_id = %s ORDER BY id",
            (analysis_id,),
        )
        job_types = [r["job_type"] for r in cur.fetchall()]

    assert len(job_types) == 6
    assert "health_analysis" in job_types
    assert "conflict_synthesis" in job_types
    mock_dispatch.assert_called_once()
