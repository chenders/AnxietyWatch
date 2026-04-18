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


def test_conflict_new_page(client):
    """GET /admin/conflicts/new returns 200 with empty form."""
    _login(client)
    resp = client.get("/admin/conflicts/new")
    assert resp.status_code == 200
    assert b"New Conflict" in resp.data


def test_conflict_create(client, app):
    """POST /admin/conflicts/new creates a conflict."""
    _login(client)
    resp = client.post("/admin/conflicts/new", data={
        "description": "Disagreement about Clonazepam reduction timeline",
        "patient_perspective": "I think the taper is too fast",
        "patient_assumptions": "Rapid tapers cause rebound anxiety",
        "patient_desired_resolution": "Slower taper schedule",
        "patient_wants_from_other": "More conservative approach",
        "psychiatrist_perspective": "Current taper follows guidelines",
        "psychiatrist_assumptions": "Patient can handle this pace",
        "psychiatrist_desired_resolution": "Stick with the current plan",
        "psychiatrist_wants_from_other": "Trust the process",
        "additional_context": "Have been on this medication for 3 years",
    }, follow_redirects=False)
    assert resp.status_code == 302  # redirect to detail page

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM conflicts LIMIT 1")
        row = cur.fetchone()
    assert row is not None
    assert row["status"] == "active"
    assert "Clonazepam" in row["description"]
    assert row["patient_perspective"] == "I think the taper is too fast"
    assert row["psychiatrist_perspective"] == "Current taper follows guidelines"


def test_conflict_detail_page(client, app):
    """GET /admin/conflicts/<id> shows conflict detail form."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective) "
            "VALUES ('Test conflict', 'My side') RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()

    resp = client.get(f"/admin/conflicts/{conflict_id}")
    assert resp.status_code == 200
    assert b"Test conflict" in resp.data
    assert b"My side" in resp.data


def test_conflict_update(client, app):
    """POST /admin/conflicts/<id> updates a conflict."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description) VALUES ('Original description') RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()

    client.post(f"/admin/conflicts/{conflict_id}", data={
        "description": "Updated description",
        "patient_perspective": "New perspective",
    }, follow_redirects=True)

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM conflicts WHERE id = %s", (conflict_id,))
        row = cur.fetchone()
    assert row["description"] == "Updated description"
    assert row["patient_perspective"] == "New perspective"


def test_conflict_resolve(client, app):
    """POST with action=resolve marks conflict as resolved."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description) VALUES ('Test conflict') RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()

    client.post(f"/admin/conflicts/{conflict_id}", data={
        "action": "resolve",
    }, follow_redirects=True)

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM conflicts WHERE id = %s", (conflict_id,))
        row = cur.fetchone()
    assert row["status"] == "resolved"
    assert row["resolved_at"] is not None


def test_conflict_reopen(client, app):
    """POST with action=reopen reopens a resolved conflict."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (status, description, resolved_at) "
            "VALUES ('resolved', 'Test conflict', NOW()) RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()

    client.post(f"/admin/conflicts/{conflict_id}", data={
        "action": "reopen",
    }, follow_redirects=True)

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM conflicts WHERE id = %s", (conflict_id,))
        row = cur.fetchone()
    assert row["status"] == "active"
    assert row["resolved_at"] is None


def test_analysis_page_shows_conflict_banner(client, app):
    """Analysis page shows banner when an active conflict exists."""
    _login(client)
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description) VALUES ('Active conflict about meds')"
        )
        db.commit()

    resp = client.get("/admin/analysis")
    assert resp.status_code == 200
    assert b"Active conflict detected" in resp.data


def test_analysis_page_no_banner_without_conflict(client):
    """Analysis page shows no banner when no active conflict exists."""
    _login(client)
    resp = client.get("/admin/analysis")
    assert resp.status_code == 200
    assert b"Active conflict detected" not in resp.data


def test_conflict_status_check_constraint(app):
    """conflicts.status only allows 'active' or 'resolved'."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        with pytest.raises(Exception):
            cur.execute(
                "INSERT INTO conflicts (status, description) VALUES ('invalid', 'test')"
            )
        db.rollback()
