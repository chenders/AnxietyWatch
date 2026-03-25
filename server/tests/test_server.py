"""Tests for Anxiety Watch sync server."""

import hashlib
import os

import psycopg2
import pytest

# Point to the server module
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from server import create_app  # noqa: E402


DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get("DATABASE_URL", "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test"),
)

TEST_API_KEY = "test-key-for-pytest-12345678"
TEST_API_KEY_HASH = hashlib.sha256(TEST_API_KEY.encode()).hexdigest()


@pytest.fixture(scope="session")
def _init_db():
    """Create tables once per test session."""
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
    """Truncate all tables before each test."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "TRUNCATE anxiety_entries, medication_definitions, medication_doses, "
            "cpap_sessions, health_snapshots, barometric_readings, sync_log, api_keys, settings, "
            "pharmacies, prescriptions, pharmacy_call_logs "
            "RESTART IDENTITY CASCADE"
        )
        # Insert a test API key
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


def auth_header():
    return {"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"}


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def test_missing_auth(client):
    resp = client.post("/api/sync", json={})
    assert resp.status_code == 401


def test_invalid_key(client):
    resp = client.post(
        "/api/sync",
        json={},
        headers={"Authorization": "Bearer wrong-key", "Content-Type": "application/json"},
    )
    assert resp.status_code == 401


def test_revoked_key(client, app):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("UPDATE api_keys SET is_active = FALSE WHERE key_hash = %s", (TEST_API_KEY_HASH,))
        db.commit()

    resp = client.get("/api/status", headers=auth_header())
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# POST /api/sync
# ---------------------------------------------------------------------------


def test_sync_empty(client):
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T00:00:00Z",
        "anxietyEntries": [],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] == "ok"
    assert all(v == 0 for v in data["counts"].values())


def test_sync_anxiety_entries(client):
    payload = {
        "syncType": "incremental",
        "exportDate": "2025-03-20T12:00:00Z",
        "anxietyEntries": [
            {
                "timestamp": "2025-03-20T10:00:00Z", "severity": 7,
                "notes": "Feeling anxious", "tags": ["work", "morning"],
            },
            {"timestamp": "2025-03-20T14:00:00Z", "severity": 3, "notes": "Better now", "tags": []},
        ],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["anxiety_entries"] == 2


def test_sync_upsert_idempotent(client):
    """Sending the same record twice should not create duplicates."""
    entry = {"timestamp": "2025-03-20T10:00:00Z", "severity": 5, "notes": "Test", "tags": []}
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T12:00:00Z",
        "anxietyEntries": [entry],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }

    client.post("/api/sync", json=payload, headers=auth_header())
    # Send again with updated severity
    entry["severity"] = 8
    client.post("/api/sync", json=payload, headers=auth_header())

    resp = client.get("/api/data/anxietyEntries", headers=auth_header())
    entries = resp.get_json()["anxietyEntries"]
    assert len(entries) == 1
    assert entries[0]["severity"] == 8


def test_sync_all_entity_types(client):
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T12:00:00Z",
        "anxietyEntries": [
            {"timestamp": "2025-03-20T10:00:00Z", "severity": 5, "notes": "", "tags": []},
        ],
        "medicationDefinitions": [
            {"name": "Lorazepam", "defaultDoseMg": 0.5, "category": "benzodiazepine", "isActive": True},
        ],
        "medicationDoses": [
            {"timestamp": "2025-03-20T09:00:00Z", "medicationName": "Lorazepam", "doseMg": 0.5, "notes": None},
        ],
        "cpapSessions": [
            {
                "date": "2025-03-20", "ahi": 2.3, "totalUsageMinutes": 420,
                "leakRate95th": 5.1, "pressureMin": 6.0, "pressureMax": 12.0, "pressureMean": 9.5,
                "obstructiveEvents": 5, "centralEvents": 2, "hypopneaEvents": 3, "importSource": "sd_card",
            },
        ],
        "healthSnapshots": [
            {
                "date": "2025-03-20", "hrvAvg": 45.2, "hrvMin": 22.0, "restingHR": 62.0,
                "sleepDurationMin": 450, "sleepDeepMin": 90, "sleepREMMin": 110,
                "sleepCoreMin": 220, "sleepAwakeMin": 30,
                "skinTempDeviation": 0.1, "respiratoryRate": 14.5, "spo2Avg": 96.2,
                "steps": 8500, "activeCalories": 350.0, "exerciseMinutes": 45,
                "environmentalSoundAvg": 55.0, "bpSystolic": 120.0, "bpDiastolic": 80.0,
                "bloodGlucoseAvg": 95.0,
            },
        ],
        "barometricReadings": [
            {"timestamp": "2025-03-20T10:30:00Z", "pressureKPa": 101.3, "relativeAltitudeM": 0.5},
        ],
    }

    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    counts = resp.get_json()["counts"]
    assert counts["anxiety_entries"] == 1
    assert counts["medication_definitions"] == 1
    assert counts["medication_doses"] == 1
    assert counts["cpap_sessions"] == 1
    assert counts["health_snapshots"] == 1
    assert counts["barometric_readings"] == 1


def test_sync_invalid_json(client):
    resp = client.post(
        "/api/sync",
        data="not json",
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"},
    )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# GET /api/data
# ---------------------------------------------------------------------------


def test_get_all_data_empty(client):
    resp = client.get("/api/data", headers=auth_header())
    assert resp.status_code == 200
    data = resp.get_json()
    assert "exportDate" in data
    assert data["anxietyEntries"] == []


def test_get_entity_data(client):
    # Sync some data first
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T12:00:00Z",
        "anxietyEntries": [
            {"timestamp": "2025-03-20T10:00:00Z", "severity": 5, "notes": "Test", "tags": ["a"]},
        ],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }
    client.post("/api/sync", json=payload, headers=auth_header())

    resp = client.get("/api/data/anxietyEntries", headers=auth_header())
    assert resp.status_code == 200
    entries = resp.get_json()["anxietyEntries"]
    assert len(entries) == 1
    assert entries[0]["severity"] == 5


def test_get_unknown_entity(client):
    resp = client.get("/api/data/unknown", headers=auth_header())
    assert resp.status_code == 404


def test_get_data_since_filter(client):
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T12:00:00Z",
        "anxietyEntries": [
            {"timestamp": "2025-03-19T10:00:00Z", "severity": 3, "notes": "Old", "tags": []},
            {"timestamp": "2025-03-20T10:00:00Z", "severity": 7, "notes": "New", "tags": []},
        ],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }
    client.post("/api/sync", json=payload, headers=auth_header())

    resp = client.get("/api/data/anxietyEntries?since=2025-03-20T00:00:00Z", headers=auth_header())
    entries = resp.get_json()["anxietyEntries"]
    assert len(entries) == 1
    assert entries[0]["severity"] == 7


# ---------------------------------------------------------------------------
# GET /api/status
# ---------------------------------------------------------------------------


def test_status(client):
    resp = client.get("/api/status", headers=auth_header())
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] == "ok"
    assert "counts" in data
    assert data["lastSync"] is None


def test_status_after_sync(client):
    payload = {
        "syncType": "full",
        "exportDate": "2025-03-20T12:00:00Z",
        "deviceName": "Chris's iPhone",
        "anxietyEntries": [],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
    }
    client.post("/api/sync", json=payload, headers=auth_header())

    resp = client.get("/api/status", headers=auth_header())
    data = resp.get_json()
    assert data["lastSync"] is not None
    assert data["lastSync"]["sync_type"] == "full"


# ---------------------------------------------------------------------------
# API key usage tracking
# ---------------------------------------------------------------------------


def test_api_key_usage_tracking(client, app):
    client.get("/api/status", headers=auth_header())
    client.get("/api/status", headers=auth_header())

    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("SELECT request_count, last_used_at FROM api_keys WHERE key_hash = %s", (TEST_API_KEY_HASH,))
        row = cur.fetchone()
        assert row[0] == 2
        assert row[1] is not None


# ---------------------------------------------------------------------------
# Admin endpoints
# ---------------------------------------------------------------------------


def test_admin_login_required(client):
    resp = client.get("/admin/")
    assert resp.status_code == 302
    assert "/admin/login" in resp.headers["Location"]


def test_admin_login(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    resp = client.post("/admin/login", data={"password": "testpass"}, follow_redirects=True)
    assert resp.status_code == 200
    assert b"Dashboard" in resp.data


def test_admin_login_wrong_password(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    resp = client.post("/admin/login", data={"password": "wrong"})
    assert b"Invalid password" in resp.data


def test_admin_create_and_revoke_key(client, app):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    # Login
    client.post("/admin/login", data={"password": "testpass"})
    # Create key
    resp = client.post("/admin/keys", data={"label": "Test Device"}, follow_redirects=True)
    assert resp.status_code == 200
    assert b"Test Device" in resp.data
    # Find the new key's ID from DB
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("SELECT id FROM api_keys WHERE label = 'Test Device'")
        key_id = cur.fetchone()[0]
    # Revoke it
    resp = client.post(f"/admin/keys/{key_id}/revoke", follow_redirects=True)
    assert resp.status_code == 200
    assert b"Revoked" in resp.data


def test_admin_data_browser(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    client.post("/admin/login", data={"password": "testpass"})
    resp = client.get("/admin/data")
    assert resp.status_code == 200
    assert b"Data Browser" in resp.data


def test_admin_logout(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    client.post("/admin/login", data={"password": "testpass"})
    client.post("/admin/logout")
    resp = client.get("/admin/")
    assert resp.status_code == 302


# ---------------------------------------------------------------------------
# ResMed Settings
# ---------------------------------------------------------------------------


def test_resmed_settings_login_required(client):
    resp = client.get("/admin/settings/resmed")
    assert resp.status_code == 302
    assert "/admin/login" in resp.headers["Location"]


def test_resmed_settings_get(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    client.post("/admin/login", data={"password": "testpass"})
    resp = client.get("/admin/settings/resmed")
    assert resp.status_code == 200
    assert b"ResMed myAir Sync" in resp.data


def test_resmed_settings_save(client, app):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    os.environ["SECRET_KEY"] = "test-secret-key"
    client.post("/admin/login", data={"password": "testpass"})
    resp = client.post(
        "/admin/settings/resmed",
        data={"action": "save", "email": "user@example.com", "password": "mypass", "sync_time": "14:00"},
        follow_redirects=True,
    )
    assert resp.status_code == 200
    assert b"Settings saved" in resp.data

    # Verify settings were persisted
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_email'")
        assert cur.fetchone()[0] == "user@example.com"
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_sync_time'")
        assert cur.fetchone()[0] == "14:00"
        # Password should be encrypted (not stored as plaintext)
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_password'")
        stored = cur.fetchone()[0]
        assert stored != "mypass"
        assert len(stored) > 0


# ---------------------------------------------------------------------------
# Pharmacy / Prescription / Call Log sync
# ---------------------------------------------------------------------------


def test_sync_pharmacies(client):
    payload = {
        "pharmacies": [
            {"name": "Walgreens #03890", "address": "123 Main St",
             "phoneNumber": "555-1234", "notes": "", "isActive": True},
        ]
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["pharmacies"] == 1


def test_sync_prescriptions(client):
    payload = {
        "prescriptions": [
            {"rxNumber": "2618630-03890", "medicationName": "Clonazepam 1mg",
             "doseMg": 1.0, "quantity": 60, "dateFilled": "2025-12-31T00:00:00Z",
             "pharmacyName": "Walgreens"},
        ]
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["prescriptions"] == 1


def test_sync_prescriptions_idempotent(client, app):
    rx = {"rxNumber": "2618630-03890", "medicationName": "Clonazepam 1mg",
          "doseMg": 1.0, "quantity": 60, "dateFilled": "2025-12-31T00:00:00Z"}
    payload = {"prescriptions": [rx]}
    client.post("/api/sync", json=payload, headers=auth_header())
    # Second sync with updated quantity to exercise DO UPDATE
    rx2 = {**rx, "quantity": 90}
    resp = client.post("/api/sync", json={"prescriptions": [rx2]}, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["prescriptions"] == 1
    # Verify only one row exists with the updated value
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("SELECT quantity FROM prescriptions WHERE rx_number = %s", (rx["rxNumber"],))
        assert cur.fetchone()[0] == 90


def test_sync_pharmacy_call_logs(client):
    payload = {
        "pharmacyCallLogs": [
            {"timestamp": "2025-12-31T14:00:00Z", "pharmacyName": "Walgreens",
             "direction": "outgoing", "notes": "Refill request"},
        ]
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["pharmacy_call_logs"] == 1
