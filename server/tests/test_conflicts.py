"""Tests for conflict CRUD and lifecycle."""

import hashlib
import os
import sys

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


def _login(client):
    client.post("/admin/login", data={"password": os.environ.get("ADMIN_PASSWORD", "test")})


def test_conflicts_list_empty(client):
    """GET /admin/conflicts returns 200 with no conflicts."""
    _login(client)
    resp = client.get("/admin/conflicts")
    assert resp.status_code == 200
    assert b"Conflicts" in resp.data
    assert b"No conflicts" in resp.data


def test_conflicts_list_shows_conflicts(client, app):
    """GET /admin/conflicts lists active and resolved conflicts."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (status, description) VALUES "
            "('active', 'Active conflict about meds'), "
            "('resolved', 'Old resolved conflict')"
        )
        db.commit()

    resp = client.get("/admin/conflicts")
    assert resp.status_code == 200
    assert b"Active conflict about meds" in resp.data
    assert b"Old resolved conflict" in resp.data
