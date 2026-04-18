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
