"""Tests for patient and psychiatrist profile management."""

import hashlib
import json
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

TEST_API_KEY = "test-key-for-pytest-12345678"
TEST_API_KEY_HASH = hashlib.sha256(TEST_API_KEY.encode()).hexdigest()


@pytest.fixture(scope="session")
def _init_db():
    """Run schema.sql once for the entire test session."""
    schema_path = os.path.join(os.path.dirname(__file__), "..", "schema.sql")
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    with conn.cursor() as cur:
        with open(schema_path) as f:
            cur.execute(f.read())
    conn.close()


@pytest.fixture()
def app(_init_db):
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    return app


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


def _get_columns(app, table_name):
    """Return set of column names for the given table via information_schema."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = %s",
            (table_name,),
        )
        return {row[0] for row in cur.fetchall()}


def test_patient_profile_table_exists(app):
    """patient_profile table must exist with all required columns."""
    columns = _get_columns(app, "patient_profile")
    expected = {
        "id",
        "name",
        "date_of_birth",
        "gender",
        "medical_history_raw",
        "medical_history_structured",
        "other_medications",
        "profile_summary",
        "updated_at",
    }
    assert expected <= columns, f"Missing columns: {expected - columns}"


def test_psychiatrist_profile_table_exists(app):
    """psychiatrist_profile table must exist with all required columns."""
    columns = _get_columns(app, "psychiatrist_profile")
    expected = {
        "id",
        "name",
        "location",
        "research_result",
        "profile_summary",
        "researched_at",
        "updated_at",
    }
    assert expected <= columns, f"Missing columns: {expected - columns}"


def test_conflicts_table_exists(app):
    """conflicts table must exist with all required columns."""
    columns = _get_columns(app, "conflicts")
    expected = {
        "id",
        "status",
        "description",
        "patient_perspective",
        "psychiatrist_perspective",
        "created_at",
        "resolved_at",
    }
    assert expected <= columns, f"Missing columns: {expected - columns}"


def _login(client):
    """Log in to admin UI."""
    client.post("/admin/login", data={"password": os.environ.get("ADMIN_PASSWORD", "test")})


def test_patient_profile_get_empty(client):
    """GET /admin/patient-profile returns 200 with empty form."""
    _login(client)
    resp = client.get("/admin/patient-profile")
    assert resp.status_code == 200
    assert b"Patient Profile" in resp.data


def test_patient_profile_save(client, app):
    """POST /admin/patient-profile saves profile fields."""
    _login(client)
    resp = client.post("/admin/patient-profile", data={
        "name": "Test User",
        "date_of_birth": "1992-03-15",
        "gender": "Male",
        "other_medications": "Vitamin D 2000IU daily",
        "medical_history_raw": "History of GAD since 2018",
    }, follow_redirects=True)
    assert resp.status_code == 200

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM patient_profile LIMIT 1")
        row = cur.fetchone()
    assert row is not None
    assert row["name"] == "Test User"
    assert str(row["date_of_birth"]) == "1992-03-15"
    assert row["gender"] == "Male"
    assert row["other_medications"] == "Vitamin D 2000IU daily"
    assert row["medical_history_raw"] == "History of GAD since 2018"


def test_patient_profile_update_existing(client, app):
    """POST /admin/patient-profile updates existing row (single-row table)."""
    _login(client)
    # Create initial profile
    client.post("/admin/patient-profile", data={
        "name": "First Name",
        "gender": "Male",
    })
    # Update it
    client.post("/admin/patient-profile", data={
        "name": "Updated Name",
        "gender": "Non-binary",
    })

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT count(*) AS cnt FROM patient_profile")
        assert cur.fetchone()["cnt"] == 1
        cur.execute("SELECT * FROM patient_profile LIMIT 1")
        row = cur.fetchone()
    assert row["name"] == "Updated Name"
    assert row["gender"] == "Non-binary"


def test_patient_profile_shows_active_medications(client, app):
    """GET /admin/patient-profile includes active medication definitions."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO medication_definitions (name, default_dose_mg, category, is_active) "
            "VALUES ('Clonazepam', 1.0, 'benzodiazepine', TRUE), "
            "('OldMed', 5.0, 'test', FALSE)"
        )
        db.commit()

    resp = client.get("/admin/patient-profile")
    assert b"Clonazepam" in resp.data
    assert b"OldMed" not in resp.data


def test_analysis_jobs_table_exists(app):
    """analysis_jobs table must exist with all required columns."""
    columns = _get_columns(app, "analysis_jobs")
    expected = {
        "id",
        "analysis_id",
        "conflict_id",
        "job_type",
        "depends_on",
        "status",
        "result",
        "model",
    }
    assert expected <= columns, f"Missing columns: {expected - columns}"
