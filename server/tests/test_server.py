"""Tests for Anxiety Watch sync server."""

import datetime
import hashlib
import json
import logging
import os
import re

import psycopg2
import psycopg2.extras
import pytest

# Point to the server module
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import admin  # noqa: E402
from crypto import decrypt_value, encrypt_value  # noqa: E402
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
            "TRUNCATE anxiety_entries, health_snapshots, medication_definitions, "
            "medication_doses, cpap_sessions, barometric_readings, correlations, "
            "analyses, api_keys, sync_log, therapy_sessions, settings, "
            "patient_profile, psychiatrist_profile, conflicts, analysis_jobs, "
            "pharmacies, prescriptions, pharmacy_call_logs, "
            "quantity_health_samples, sleep_stage_events, "
            "sensor_sessions, hrv_readings, "
            "songs, song_occurrences "
            "RESTART IDENTITY CASCADE"
        )
        # Insert a test API key
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


# Login-failure throttling (F-034) state lives in the `settings` table, which
# `_clean_tables` already truncates before every test — no separate reset hook
# is needed. (It moved out of module-level state so the lockout holds across
# gunicorn workers; see admin.login.)


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
                "cpapAHI": 2.3, "cpapUsageMinutes": 420,
                "barometricPressureAvgKPa": 101.3, "barometricPressureChangeKPa": 0.5,
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


def test_sync_health_snapshot_cpap_barometric_fields(client, app):
    """CPAP and barometric fields round-trip through sync and read back."""
    payload = {
        "healthSnapshots": [
            {
                "date": "2025-03-20", "hrvAvg": 45.0,
                "cpapAHI": 3.1, "cpapUsageMinutes": 380,
                "barometricPressureAvgKPa": 100.8, "barometricPressureChangeKPa": 1.2,
            },
        ],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["health_snapshots"] == 1

    # Read back and verify
    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    rows = resp.get_json()["healthSnapshots"]
    assert len(rows) == 1
    row = rows[0]
    assert row["cpap_ahi"] == 3.1
    assert row["cpap_usage_minutes"] == 380
    assert row["barometric_pressure_avg_kpa"] == 100.8
    assert row["barometric_pressure_change_kpa"] == 1.2


def test_sync_health_snapshot_cpap_barometric_null(client, app):
    """CPAP and barometric fields default to null when omitted."""
    payload = {
        "healthSnapshots": [
            {"date": "2025-03-21", "hrvAvg": 50.0},
        ],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    row = resp.get_json()["healthSnapshots"][0]
    assert row["cpap_ahi"] is None
    assert row["cpap_usage_minutes"] is None
    assert row["barometric_pressure_avg_kpa"] is None
    assert row["barometric_pressure_change_kpa"] is None


def test_sync_health_snapshot_overnight_clinical_stats(client, app):
    """The seven new overnight clinical stat fields round-trip through sync."""
    payload = {
        "healthSnapshots": [
            {
                "date": "2025-03-22",
                "hrvAvg": 45.0,
                "spo2NadirOvernight": 87.0,
                "spo2TimeBelow90Min": 12,
                "spo2DesatsCount": 4,
                "glucoseStdDev": 22.0,
                "glucoseCV": 18.5,
                "glucoseMin": 80.0,
                "glucoseMax": 165.0,
            },
        ],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["health_snapshots"] == 1

    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    rows = resp.get_json()["healthSnapshots"]
    assert len(rows) == 1
    row = rows[0]
    assert row["spo2_nadir_overnight"] == 87.0
    assert row["spo2_time_below_90_min"] == 12
    assert row["spo2_desats_count"] == 4
    assert row["glucose_std_dev"] == 22.0
    assert row["glucose_cv"] == 18.5
    assert row["glucose_min"] == 80.0
    assert row["glucose_max"] == 165.0


def test_sync_health_snapshot_overnight_stats_null(client, app):
    """Overnight clinical stat fields default to null when omitted."""
    payload = {
        "healthSnapshots": [
            {"date": "2025-03-23", "hrvAvg": 55.0},
        ],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    row = resp.get_json()["healthSnapshots"][0]
    for field in (
        "spo2_nadir_overnight",
        "spo2_time_below_90_min",
        "spo2_desats_count",
        "glucose_std_dev",
        "glucose_cv",
        "glucose_min",
        "glucose_max",
    ):
        assert row[field] is None, f"{field} should be null when omitted"


def test_sync_health_snapshot_overnight_stats_older_client_does_not_wipe(client, app):
    """A v1 (or no-version) sync that omits the new keys must not overwrite
    previously-synced values with NULL. The seven overnight stat columns
    use COALESCE under the v1 path so missing keys are preserved.
    """
    # First sync: modern client (v2) with full overnight stats
    full_payload = {
        "syncSchemaVersion": 2,
        "healthSnapshots": [
            {
                "date": "2025-03-25",
                "spo2NadirOvernight": 87.0,
                "spo2TimeBelow90Min": 12,
                "spo2DesatsCount": 4,
                "glucoseStdDev": 22.0,
                "glucoseCV": 18.5,
                "glucoseMin": 80.0,
                "glucoseMax": 165.0,
            },
        ],
    }
    resp = client.post("/api/sync", json=full_payload, headers=auth_header())
    assert resp.status_code == 200

    # Second sync: older client (no syncSchemaVersion key — defaults to v1)
    # that doesn't know about the new fields. Triggers ON CONFLICT DO UPDATE.
    older_payload = {
        "healthSnapshots": [
            {"date": "2025-03-25", "hrvAvg": 50.0},
        ],
    }
    resp = client.post("/api/sync", json=older_payload, headers=auth_header())
    assert resp.status_code == 200

    # The seven overnight stat fields are preserved (COALESCE protected),
    # but hrvAvg was updated normally.
    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    row = next(r for r in resp.get_json()["healthSnapshots"] if r["date"] == "2025-03-25")
    assert row["hrv_avg"] == 50.0
    assert row["spo2_nadir_overnight"] == 87.0
    assert row["spo2_time_below_90_min"] == 12
    assert row["spo2_desats_count"] == 4
    assert row["glucose_std_dev"] == 22.0
    assert row["glucose_cv"] == 18.5
    assert row["glucose_min"] == 80.0
    assert row["glucose_max"] == 165.0


def test_sync_health_snapshot_overnight_stats_v2_client_can_clear(client, app):
    """A v2 client that re-aggregates a snapshot to nil (e.g., HealthKit data
    deleted, threshold not met) sends the keys missing — Codable's
    encodeIfPresent omits nil-valued optionals. v2 semantics treat that as
    an intentional clear, so the columns go to NULL on conflict.
    """
    # Initial v2 sync with values populated
    initial = {
        "syncSchemaVersion": 2,
        "healthSnapshots": [
            {
                "date": "2025-03-26",
                "spo2NadirOvernight": 90.0,
                "glucoseCV": 20.0,
                "glucoseMin": 85.0,
                "glucoseMax": 140.0,
            },
        ],
    }
    resp = client.post("/api/sync", json=initial, headers=auth_header())
    assert resp.status_code == 200

    # Re-sync at v2 with the keys omitted (modern client's recompute → nil)
    cleared = {
        "syncSchemaVersion": 2,
        "healthSnapshots": [
            {"date": "2025-03-26", "hrvAvg": 60.0},
        ],
    }
    resp = client.post("/api/sync", json=cleared, headers=auth_header())
    assert resp.status_code == 200

    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    row = next(r for r in resp.get_json()["healthSnapshots"] if r["date"] == "2025-03-26")
    assert row["hrv_avg"] == 60.0
    assert row["spo2_nadir_overnight"] is None
    assert row["glucose_cv"] is None
    assert row["glucose_min"] is None
    assert row["glucose_max"] is None


def test_sync_health_snapshot_overnight_stats_upsert(client, app):
    """The new fields update on conflict when both old and new are non-null."""
    initial = {
        "healthSnapshots": [
            {
                "date": "2025-03-24",
                "spo2NadirOvernight": 92.0,
                "glucoseCV": 14.0,
            },
        ],
    }
    resp = client.post("/api/sync", json=initial, headers=auth_header())
    assert resp.status_code == 200

    updated = {
        "healthSnapshots": [
            {
                "date": "2025-03-24",
                "spo2NadirOvernight": 85.0,
                "glucoseCV": 28.0,
            },
        ],
    }
    resp = client.post("/api/sync", json=updated, headers=auth_header())
    assert resp.status_code == 200

    resp = client.get("/api/data/healthSnapshots", headers=auth_header())
    rows = resp.get_json()["healthSnapshots"]
    same_day = [r for r in rows if r["date"] == "2025-03-24"]
    assert len(same_day) == 1
    assert same_day[0]["spo2_nadir_overnight"] == 85.0
    assert same_day[0]["glucose_cv"] == 28.0


def _fetch_quantity_samples(app):
    """Return all rows from quantity_health_samples ordered by timestamp."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT id, timestamp, metric_type, value, unit_string, "
            "source_bundle_id, source_name, device_model, group_id "
            "FROM quantity_health_samples ORDER BY timestamp"
        )
        return cur.fetchall()


def _fetch_sleep_events(app):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT id, start_time, end_time, stage, source_bundle_id, "
            "source_name, device_model "
            "FROM sleep_stage_events ORDER BY start_time"
        )
        return cur.fetchall()


def _fetch_health_snapshot(app, day):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM health_snapshots WHERE date = %s",
            (day,),
        )
        return cur.fetchone()


# Per-metric production-shape defaults for the quantity-sample test fixture.
# Bundle IDs match `DeviceProvenance.continuousGlucoseMonitors` /
# `overnightPulseOximeters` / `appleEcosystemSources` on the iOS side so the
# server tests assert against the same identifiers production clients send.
# Units match what `HKUnit.unitString` actually serializes to (see
# `SampleCaptureRegistry`): glucose → "mg/dL", SpO₂ → "%", heart rate →
# "count/min", systolic/diastolic → "mmHg".
_METRIC_DEFAULTS = {
    "HKQuantityTypeIdentifierBloodGlucose": {
        "unitString": "mg/dL",
        "sourceBundleID": "com.dexcom.stelo",
        "sourceName": "Stelo",
        "deviceModel": "Stelo G7",
    },
    "HKQuantityTypeIdentifierOxygenSaturation": {
        "unitString": "%",
        "sourceBundleID": "com.emay.sleepo2",
        "sourceName": "EMAY SleepO2",
        "deviceModel": "EMAY SleepO2",
    },
    "HKQuantityTypeIdentifierHeartRate": {
        "unitString": "count/min",
        "sourceBundleID": "com.apple.health",
        "sourceName": "Apple Watch",
        "deviceModel": "Watch10,1",
    },
    "HKQuantityTypeIdentifierBloodPressureSystolic": {
        "unitString": "mmHg",
        "sourceBundleID": "com.omronhealthcare.OmronConnect",
        "sourceName": "Omron",
        "deviceModel": "Omron BP",
    },
    "HKQuantityTypeIdentifierBloodPressureDiastolic": {
        "unitString": "mmHg",
        "sourceBundleID": "com.omronhealthcare.OmronConnect",
        "sourceName": "Omron",
        "deviceModel": "Omron BP",
    },
}


def _make_quantity_samples(count, metric_type=None):
    """Build `count` quantity samples with stable, varied UUIDs.

    Uses the canonical `HKQuantityTypeIdentifier<X>` strings the iOS client
    actually sends (rather than short forms like "bloodGlucose") so server
    tests reflect production payload shape.

    Per-metric `unitString` and `sourceBundleID` come from `_METRIC_DEFAULTS`
    so SpO₂ rows aren't tagged "mg/dL" and glucose rows aren't tagged with a
    placeholder bundle ID. Bundle IDs match production CGM / pulse-oximeter /
    Apple-Watch identifiers (see `DeviceProvenance` on the iOS side) so the
    fixture round-trips representative production data.

    `metric_type=None` (the default) round-robins through glucose / SpO₂ /
    heart-rate to give multi-metric coverage; pass a single
    `HKQuantityTypeIdentifier...` string to pin every sample to one metric
    (useful for bundle-ID assertions or single-metric volume tests).

    Timestamps are generated via `datetime` arithmetic (5-minute cadence) so
    larger counts (>24) don't produce invalid hour-of-day strings like
    `T24:00:00Z`. CGM-volume tests need to push thousands of samples through
    this helper to exercise SQLite parameter limits, so the previous
    hour-by-index approach was fundamentally broken once `count > 24`.
    """
    samples = []
    if metric_type is None:
        metric_types = [
            "HKQuantityTypeIdentifierBloodGlucose",
            "HKQuantityTypeIdentifierOxygenSaturation",
            "HKQuantityTypeIdentifierHeartRate",
        ]
    else:
        metric_types = [metric_type]
    base = datetime.datetime(2026, 5, 4, 0, 0, 0, tzinfo=datetime.timezone.utc)
    for i in range(count):
        # Stable UUIDs derived from the index — deterministic + reproducible.
        sid = f"00000000-0000-0000-0000-{i:012d}"
        gid = f"11111111-1111-1111-1111-{i:012d}"
        ts = base + datetime.timedelta(minutes=5 * i)
        mt = metric_types[i % len(metric_types)]
        defaults = _METRIC_DEFAULTS[mt]
        samples.append({
            "id": sid,
            "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "metricType": mt,
            "value": 90.0 + i,
            "unitString": defaults["unitString"],
            "sourceBundleID": defaults["sourceBundleID"],
            "sourceName": defaults["sourceName"],
            "deviceModel": defaults["deviceModel"],
            "groupId": gid,
        })
    return samples


def test_sync_quantity_samples_round_trip(client, app):
    """quantitySamples in /api/sync payload land in quantity_health_samples."""
    samples = _make_quantity_samples(10)
    payload = {"syncSchemaVersion": 3, "quantitySamples": samples}

    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200, resp.get_json()

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 10

    # Spot-check the first sample's fields round-trip.
    first = rows[0]
    assert str(first["id"]) == samples[0]["id"]
    assert first["metric_type"] == samples[0]["metricType"]
    assert first["value"] == samples[0]["value"]
    assert first["unit_string"] == samples[0]["unitString"]
    assert first["source_bundle_id"] == samples[0]["sourceBundleID"]
    assert first["source_name"] == samples[0]["sourceName"]
    assert first["device_model"] == samples[0]["deviceModel"]
    assert str(first["group_id"]) == samples[0]["groupId"]


def test_sync_quantity_samples_idempotent(client, app):
    """Replaying the same quantity samples twice keeps row count at 10."""
    samples = _make_quantity_samples(10)
    payload = {"syncSchemaVersion": 3, "quantitySamples": samples}

    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 10


def test_sync_quantity_samples_replay_updates(client, app):
    """Re-posting the same id with a new value updates the existing row."""
    samples = _make_quantity_samples(1)
    sid = samples[0]["id"]
    payload = {"syncSchemaVersion": 3, "quantitySamples": samples}
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    # Replay with a new value (HealthKit retroactive correction scenario).
    samples[0]["value"] = 142.5
    samples[0]["sourceName"] = "Stelo (corrected)"
    samples[0]["deviceModel"] = "Stelo G7 v2"
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 1
    assert rows[0]["value"] == 142.5
    assert rows[0]["source_name"] == "Stelo (corrected)"
    assert rows[0]["device_model"] == "Stelo G7 v2"
    # Identity didn't change.
    assert str(rows[0]["id"]) == sid


def test_sync_quantity_samples_replay_backfills_group_id(client, app):
    """Replaying a row that originally had no groupId should backfill it.

    Mirrors the future HKCorrelation linking flow: a client posts a glucose
    or BP reading without a groupId on first sync, then later identifies
    the correlation and replays the same id with a groupId attached. The
    server must update the column without overwriting an existing non-null
    group_id (handled by COALESCE(EXCLUDED.group_id, ...)).
    """
    samples = _make_quantity_samples(1)
    sid = samples[0]["id"]
    samples[0]["groupId"] = None
    payload = {"syncSchemaVersion": 3, "quantitySamples": samples}
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 1
    assert rows[0]["group_id"] is None

    # Replay with a now-known groupId; server should backfill the column.
    new_group = "33333333-3333-3333-3333-000000000001"
    samples[0]["groupId"] = new_group
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 1
    assert str(rows[0]["group_id"]) == new_group
    assert str(rows[0]["id"]) == sid

    # A subsequent replay that omits groupId must NOT clear the existing one
    # — COALESCE(NULL, existing) keeps the previously-stored correlation.
    samples[0]["groupId"] = None
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert str(rows[0]["group_id"]) == new_group


def test_sync_quantity_samples_replay_updates_timestamp_and_metric(client, app):
    """Replays must overwrite identity columns too — HealthKit can issue
    retroactive corrections that change `timestamp`, `metricType`,
    `unitString`, or `sourceBundleID` while keeping the same uuid (e.g.,
    CGM backfill, sensor recalibration). The previous ON CONFLICT clause
    only updated value/source_name/device_model, which silently dropped
    those corrections on the floor.
    """
    samples = _make_quantity_samples(1)
    sid = samples[0]["id"]
    samples[0]["timestamp"] = "2026-05-04T00:00:00Z"
    samples[0]["metricType"] = "HKQuantityTypeIdentifierBloodGlucose"
    samples[0]["unitString"] = "mg/dL"
    samples[0]["sourceBundleID"] = "com.dexcom.stelo"
    payload = {"syncSchemaVersion": 3, "quantitySamples": samples}
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    # Replay with corrected identity fields under the same uuid.
    samples[0]["timestamp"] = "2026-05-04T00:05:00Z"
    samples[0]["metricType"] = "HKQuantityTypeIdentifierOxygenSaturation"
    samples[0]["unitString"] = "%"
    samples[0]["sourceBundleID"] = "com.apple.health"
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    rows = _fetch_quantity_samples(app)
    assert len(rows) == 1
    row = rows[0]
    assert str(row["id"]) == sid
    # Identity columns reflect the replay, not the original insert. The DB
    # may return a TZ-aware datetime in any offset; normalize to UTC before
    # comparing so we're testing the instant, not the textual representation.
    expected = datetime.datetime(2026, 5, 4, 0, 5, 0, tzinfo=datetime.timezone.utc)
    actual_utc = row["timestamp"].astimezone(datetime.timezone.utc)
    assert actual_utc == expected
    assert row["metric_type"] == "HKQuantityTypeIdentifierOxygenSaturation"
    assert row["unit_string"] == "%"
    assert row["source_bundle_id"] == "com.apple.health"


def test_sync_sleep_stage_events_round_trip(client, app):
    """sleepStageEvents in payload land in sleep_stage_events."""
    events = [
        {
            "id": "22222222-2222-2222-2222-000000000001",
            "startTime": "2026-05-04T03:00:00Z",
            "endTime": "2026-05-04T03:45:00Z",
            "stage": "asleepCore",
            "sourceBundleID": "com.apple.health",
            "sourceName": "Apple Watch",
            "deviceModel": "Watch10,1",
        },
        {
            "id": "22222222-2222-2222-2222-000000000002",
            "startTime": "2026-05-04T03:45:00Z",
            "endTime": "2026-05-04T04:30:00Z",
            "stage": "asleepREM",
            "sourceBundleID": "com.apple.health",
        },
        {
            "id": "22222222-2222-2222-2222-000000000003",
            "startTime": "2026-05-04T04:30:00Z",
            "endTime": "2026-05-04T05:15:00Z",
            "stage": "asleepDeep",
            "sourceBundleID": "com.apple.health",
            "sourceName": "Apple Watch",
        },
    ]
    payload = {"syncSchemaVersion": 3, "sleepStageEvents": events}

    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200, resp.get_json()

    rows = _fetch_sleep_events(app)
    assert len(rows) == 3
    assert [r["stage"] for r in rows] == ["asleepCore", "asleepREM", "asleepDeep"]
    assert rows[0]["source_bundle_id"] == "com.apple.health"
    assert rows[0]["device_model"] == "Watch10,1"


def test_sync_sleep_stage_events_replay_updates_interval(client, app):
    """Replaying a sleep stage event with corrected timestamps updates the row.

    Same `id`, but corrected `startTime`/`endTime` and `sourceBundleID`. The
    upsert's ON CONFLICT branch must apply the new interval rather than
    silently keeping the original.
    """
    event_id = "33333333-3333-3333-3333-000000000001"

    initial = [{
        "id": event_id,
        "startTime": "2026-05-04T03:00:00Z",
        "endTime": "2026-05-04T03:30:00Z",
        "stage": "asleepCore",
        "sourceBundleID": "com.apple.health.original",
        "sourceName": "Apple Watch",
        "deviceModel": "Watch10,1",
    }]
    resp = client.post(
        "/api/sync",
        json={"syncSchemaVersion": 3, "sleepStageEvents": initial},
        headers=auth_header(),
    )
    assert resp.status_code == 200, resp.get_json()

    corrected = [{
        "id": event_id,
        "startTime": "2026-05-04T03:05:00Z",
        "endTime": "2026-05-04T03:55:00Z",
        "stage": "asleepREM",
        "sourceBundleID": "com.apple.health.corrected",
        "sourceName": "Apple Watch (renamed)",
        "deviceModel": "Watch10,2",
    }]
    resp = client.post(
        "/api/sync",
        json={"syncSchemaVersion": 3, "sleepStageEvents": corrected},
        headers=auth_header(),
    )
    assert resp.status_code == 200, resp.get_json()

    rows = _fetch_sleep_events(app)
    assert len(rows) == 1
    row = rows[0]
    assert str(row["id"]) == event_id
    # Interval must reflect the replay, not the initial values. Compare in UTC
    # since psycopg2 may return rows in the session's local tz.
    expected_start = datetime.datetime(2026, 5, 4, 3, 5, tzinfo=datetime.timezone.utc)
    expected_end = datetime.datetime(2026, 5, 4, 3, 55, tzinfo=datetime.timezone.utc)
    assert row["start_time"].astimezone(datetime.timezone.utc) == expected_start
    assert row["end_time"].astimezone(datetime.timezone.utc) == expected_end
    assert row["stage"] == "asleepREM"
    assert row["source_bundle_id"] == "com.apple.health.corrected"
    assert row["source_name"] == "Apple Watch (renamed)"
    assert row["device_model"] == "Watch10,2"


def test_sync_data_quality_v3_clear_on_conflict(client, app):
    """v3 client: omitting dataQuality on a follow-up sync clears the column."""
    initial = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{
            "date": "2026-05-04",
            "hrvAvg": 50.0,
            "dataQuality": {
                "glucose": {"reliability": "high", "sources": {"com.dexcom.stelo": 287}},
                "spo2": {"reliability": "medium", "sources": {"com.apple.health": 1438}},
            },
        }],
    }
    resp = client.post("/api/sync", json=initial, headers=auth_header())
    assert resp.status_code == 200

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row["data_quality"] is not None
    assert row["data_quality"]["glucose"]["reliability"] == "high"

    # Re-sync at v3 with dataQuality omitted (modern client recompute → nil).
    cleared = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{"date": "2026-05-04", "hrvAvg": 55.0}],
    }
    resp = client.post("/api/sync", json=cleared, headers=auth_header())
    assert resp.status_code == 200

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row["hrv_avg"] == 55.0
    assert row["data_quality"] is None


def test_sync_data_quality_v2_preserves(client, app):
    """v1/v2 client: omitting dataQuality preserves a previously-synced value.

    A v3 sync seeds the column. A subsequent sync without `syncSchemaVersion`
    (treated as v1) must NOT wipe the JSONB block, since the older client may
    simply not know about the field.
    """
    initial = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{
            "date": "2026-05-04",
            "dataQuality": {"glucose": {"reliability": "high", "sources": {"com.dexcom.stelo": 287}}},
        }],
    }
    resp = client.post("/api/sync", json=initial, headers=auth_header())
    assert resp.status_code == 200

    # Older client (no version flag) updates only hrvAvg; dataQuality omitted.
    older = {
        "healthSnapshots": [{"date": "2026-05-04", "hrvAvg": 60.0}],
    }
    resp = client.post("/api/sync", json=older, headers=auth_header())
    assert resp.status_code == 200

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row["hrv_avg"] == 60.0
    assert row["data_quality"] is not None
    assert row["data_quality"]["glucose"]["reliability"] == "high"


def test_sync_health_snapshot_data_quality_invalid_json_string_treated_as_null(client, app):
    """A malformed dataQuality string must not 500 the request — coerce to NULL."""
    payload = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{
            "date": "2026-05-04",
            "hrvAvg": 50.0,
            "dataQuality": "not-json",
        }],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200, resp.get_json()

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row is not None
    assert row["hrv_avg"] == 50.0
    assert row["data_quality"] is None


def test_sync_health_snapshot_data_quality_valid_json_string_round_trips(client, app):
    """A valid JSON string for dataQuality is parsed and stored as JSONB."""
    quality = {
        "glucose": {"reliability": "high", "sources": {"com.dexcom.stelo": 287}},
        "spo2": {"reliability": "medium", "sources": {"com.apple.health": 1438}},
    }
    payload = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{
            "date": "2026-05-04",
            "hrvAvg": 50.0,
            "dataQuality": json.dumps(quality),
        }],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200, resp.get_json()

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row is not None
    assert row["data_quality"] == quality


def test_sync_health_snapshot_data_quality_dict_round_trips(client, app):
    """A dict dataQuality round-trips into the JSONB column intact."""
    quality = {
        "glucose": {"reliability": "high", "sources": {"com.dexcom.stelo": 287}},
    }
    payload = {
        "syncSchemaVersion": 3,
        "healthSnapshots": [{
            "date": "2026-05-04",
            "hrvAvg": 50.0,
            "dataQuality": quality,
        }],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200, resp.get_json()

    row = _fetch_health_snapshot(app, "2026-05-04")
    assert row is not None
    assert row["data_quality"] == quality


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


def test_get_data_exports_restore_entities(client):
    """The entities added for the restore-from-server flow (sensorSessions,
    hrvReadings, songs, songOccurrences, sleepStageEvents) must round-trip
    through GET /api/data."""
    session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    reading_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    payload = {
        "syncSchemaVersion": 3,
        "sensorSessions": [_polar_session_payload(session_id)],
        "hrvReadings": [_hrv_reading_payload(reading_id, session_id)],
        "songs": [{"title": "Test Song", "artist": "Test Artist"}],
        "sleepStageEvents": [{
            "id": "abcdefab-cdef-abcd-efab-cdefabcdef99",
            "startTime": "2026-05-11T04:00:00Z",
            "endTime": "2026-05-11T04:30:00Z",
            "stage": "asleepDeep",
            "sourceBundleID": "test.bundle",
            "sourceName": "Test Apple Watch",
        }],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    for entity, expected_count in [
        ("sensorSessions", 1),
        ("hrvReadings", 1),
        ("songs", 1),
        ("sleepStageEvents", 1),
    ]:
        resp = client.get(f"/api/data/{entity}", headers=auth_header())
        assert resp.status_code == 200, entity
        assert len(resp.get_json()[entity]) == expected_count, entity


def test_get_data_drops_bytea_columns_from_json(client):
    """sensor_sessions.rr_archive is BYTEA; psycopg returns it as a
    memoryview, which json.dumps cannot serialize. The export path must
    null it out rather than 500 on any session that has an archive."""
    session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    resp = client.post(
        f"/api/sensor_sessions/{session_id}/rr_archive",
        data=b"\x1f\x8b-fake-gzip-bytes",
        headers=auth_header(),
    )
    assert resp.status_code == 200

    resp = client.get("/api/data/sensorSessions", headers=auth_header())
    assert resp.status_code == 200
    sessions = resp.get_json()["sensorSessions"]
    assert len(sessions) == 1
    assert sessions[0]["rr_archive"] is None


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
        "deviceName": "Test iPhone",
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


# ---------------------------------------------------------------------------
# Admin login throttling (F-034)
# ---------------------------------------------------------------------------


def test_admin_login_failures_below_threshold_still_allow_login(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    for _ in range(admin.MAX_LOGIN_FAILURES - 1):
        resp = client.post("/admin/login", data={"password": "distinctive-wrong-value"})
        assert resp.status_code == 200
        assert b"Invalid password" in resp.data
    resp = client.post("/admin/login", data={"password": "testpass"})
    assert resp.status_code == 302


def test_admin_login_lockout_blocks_even_correct_password(client, app, monkeypatch):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    fake_now = {"t": 1000.0}
    monkeypatch.setattr(admin, "_now", lambda: fake_now["t"])

    for _ in range(admin.MAX_LOGIN_FAILURES):
        client.post("/admin/login", data={"password": "distinctive-wrong-value"})

    # State is shared via the settings table (holds across gunicorn workers),
    # not a per-process counter.
    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT value FROM settings WHERE key = %s", (admin._FAILURES_KEY,))
        assert int(cur.fetchone()[0]) == admin.MAX_LOGIN_FAILURES

    # Locked: even the correct password is refused with a fixed message.
    resp = client.post("/admin/login", data={"password": "testpass"})
    assert resp.status_code == 429
    assert b"Too many attempts" in resp.data

    # Once the window passes, the correct password works again.
    fake_now["t"] += admin.LOGIN_LOCKOUT_SECONDS + 1
    resp = client.post("/admin/login", data={"password": "testpass"})
    assert resp.status_code == 302


def test_admin_login_success_resets_failure_counter(client):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    for _ in range(admin.MAX_LOGIN_FAILURES - 1):
        client.post("/admin/login", data={"password": "distinctive-wrong-value"})
    resp = client.post("/admin/login", data={"password": "testpass"})
    assert resp.status_code == 302
    # Counter reset: another below-threshold run of failures must not lock.
    for _ in range(admin.MAX_LOGIN_FAILURES - 1):
        resp = client.post("/admin/login", data={"password": "distinctive-wrong-value"})
        assert resp.status_code == 200
    resp = client.post("/admin/login", data={"password": "testpass"})
    assert resp.status_code == 302


def test_admin_login_failure_logs_counter_only(client, caplog):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    with caplog.at_level(logging.WARNING, logger="admin"):
        client.post("/admin/login", data={"password": "distinctive-wrong-value"})
        client.post("/admin/login", data={"password": "distinctive-wrong-value"})
    assert "consecutive failures: 2" in caplog.text
    # Never the submitted value — and nothing derived from it (no length).
    assert "distinctive-wrong-value" not in caplog.text


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


def test_admin_create_key_shown_once_and_never_in_session_cookie(client, app):
    """F-033: the raw API key is rendered exactly once, directly in the POST
    response — it must never round-trip through the session cookie (signed
    but not encrypted) and must not reappear on a subsequent GET."""
    os.environ["ADMIN_PASSWORD"] = "testpass"
    client.post("/admin/login", data={"password": "testpass"})

    resp = client.post("/admin/keys", data={"label": "One Shot"})
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    match = re.search(r'<div class="key-display">([^<]+)</div>', body)
    assert match, "raw key not shown in the create-key response"
    raw_key = match.group(1)

    # Never serialized into the session.
    with client.session_transaction() as sess:
        assert "new_key" not in sess

    # Not shown again on a later GET.
    resp = client.get("/admin/keys")
    assert raw_key not in resp.get_data(as_text=True)

    # The shown key really is the one that was stored (hash matches).
    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT key_hash FROM api_keys WHERE label = 'One Shot'")
        stored_hash = cur.fetchone()[0]
    assert stored_hash == hashlib.sha256(raw_key.encode()).hexdigest()


def test_session_cookie_secure_defaults_off(monkeypatch):
    """F-033: Secure flag defaults OFF for the plain-HTTP LAN deployment."""
    monkeypatch.delenv("SESSION_COOKIE_SECURE", raising=False)
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    assert app.config["SESSION_COOKIE_SECURE"] is False


def test_session_cookie_secure_env_var_enables(monkeypatch):
    monkeypatch.setenv("SESSION_COOKIE_SECURE", "1")
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    assert app.config["SESSION_COOKIE_SECURE"] is True


def test_session_cookie_secure_non_truthy_value_stays_off(monkeypatch):
    monkeypatch.setenv("SESSION_COOKIE_SECURE", "0")
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    assert app.config["SESSION_COOKIE_SECURE"] is False


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
        # Email is encrypted at rest (F-080) — never stored plaintext, but
        # the sync read path decrypts it back to the identifier.
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_email'")
        stored_email = cur.fetchone()[0]
        assert stored_email != "user@example.com"
        assert decrypt_value(stored_email, "test-secret-key") == "user@example.com"
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_sync_time'")
        assert cur.fetchone()[0] == "14:00"
        # Password should be encrypted (not stored as plaintext)
        cur.execute("SELECT value FROM settings WHERE key = 'resmed_password'")
        stored = cur.fetchone()[0]
        assert stored != "mypass"
        assert len(stored) > 0

    # The settings page reports presence only — it never echoes the address.
    resp = client.get("/admin/settings/resmed")
    assert resp.status_code == 200
    assert b"user@example.com" not in resp.data
    assert b"Leave blank to keep current email" in resp.data


def _insert_setting(app, key, value):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (%s, %s, NOW()) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            (key, value),
        )
        db.commit()


def _read_setting(app, key):
    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
        row = cur.fetchone()
        return row[0] if row else None


def test_resmed_settings_legacy_plaintext_email_upgrades_on_save(client, app):
    """F-080: a legacy plaintext resmed_email still works (page shows
    presence, never the value) and gets re-encrypted on the next save even
    when the form leaves the email field blank."""
    os.environ["ADMIN_PASSWORD"] = "testpass"
    os.environ["SECRET_KEY"] = "test-secret-key"
    _insert_setting(app, "resmed_email", "legacy-user@example.com")
    client.post("/admin/login", data={"password": "testpass"})

    # GET never echoes the legacy plaintext value.
    resp = client.get("/admin/settings/resmed")
    assert b"legacy-user@example.com" not in resp.data
    assert b"Leave blank to keep current email" in resp.data

    # Save with the email field blank → the stored value is upgraded in place.
    resp = client.post(
        "/admin/settings/resmed",
        data={"action": "save", "email": "", "password": "", "sync_time": "21:00"},
        follow_redirects=True,
    )
    assert b"Settings saved" in resp.data
    stored = _read_setting(app, "resmed_email")
    assert stored != "legacy-user@example.com"
    assert decrypt_value(stored, "test-secret-key") == "legacy-user@example.com"


def test_walgreens_settings_save_encrypts_username(client, app):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    os.environ["SECRET_KEY"] = "test-secret-key"
    client.post("/admin/login", data={"password": "testpass"})
    resp = client.post(
        "/admin/settings/walgreens",
        data={
            "action": "save", "username": "wag-user@example.com",
            "password": "mypass", "security_answer": "", "sync_time": "21:00",
        },
        follow_redirects=True,
    )
    assert resp.status_code == 200
    assert b"Settings saved" in resp.data

    stored = _read_setting(app, "walgreens_username")
    assert stored != "wag-user@example.com"
    assert decrypt_value(stored, "test-secret-key") == "wag-user@example.com"

    # Presence-only rendering — the identifier is never echoed into the form.
    resp = client.get("/admin/settings/walgreens")
    assert b"wag-user@example.com" not in resp.data
    assert b"Leave blank to keep current username" in resp.data


def test_walgreens_settings_legacy_plaintext_username_upgrades_on_save(client, app):
    os.environ["ADMIN_PASSWORD"] = "testpass"
    os.environ["SECRET_KEY"] = "test-secret-key"
    _insert_setting(app, "walgreens_username", "legacy-wag@example.com")
    client.post("/admin/login", data={"password": "testpass"})

    resp = client.post(
        "/admin/settings/walgreens",
        data={
            "action": "save", "username": "",
            "password": "", "security_answer": "", "sync_time": "21:00",
        },
        follow_redirects=True,
    )
    assert b"Settings saved" in resp.data
    stored = _read_setting(app, "walgreens_username")
    assert stored != "legacy-wag@example.com"
    assert decrypt_value(stored, "test-secret-key") == "legacy-wag@example.com"


def test_upgrade_does_not_touch_already_encrypted_value(client, app):
    """The lazy re-encrypt must never double-encrypt a value that already
    decrypts cleanly — that would corrupt it."""
    os.environ["ADMIN_PASSWORD"] = "testpass"
    os.environ["SECRET_KEY"] = "test-secret-key"
    encrypted = encrypt_value("stable-user@example.com", "test-secret-key")
    _insert_setting(app, "resmed_email", encrypted)
    client.post("/admin/login", data={"password": "testpass"})

    client.post(
        "/admin/settings/resmed",
        data={"action": "save", "email": "", "password": "", "sync_time": "21:00"},
        follow_redirects=True,
    )
    stored = _read_setting(app, "resmed_email")
    assert stored == encrypted
    assert decrypt_value(stored, "test-secret-key") == "stable-user@example.com"


# ---------------------------------------------------------------------------
# Pharmacy / Prescription / Call Log sync
# ---------------------------------------------------------------------------


def test_sync_pharmacies(client):
    payload = {
        "pharmacies": [
            {"name": "Walgreens #12345", "address": "123 Main St",
             "phoneNumber": "555-1234", "notes": "", "isActive": True},
        ]
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["pharmacies"] == 1


def test_sync_prescriptions(client):
    payload = {
        "prescriptions": [
            {"rxNumber": "9999999-00001", "medicationName": "Clonazepam 1mg",
             "doseMg": 1.0, "quantity": 60, "dateFilled": "2025-12-31T00:00:00Z",
             "pharmacyName": "Walgreens"},
        ]
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["prescriptions"] == 1


def test_sync_prescriptions_idempotent(client, app):
    rx = {"rxNumber": "9999999-00001", "medicationName": "Clonazepam 1mg",
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


# ---------------------------------------------------------------------------
# Song endpoints
# ---------------------------------------------------------------------------


def test_search_songs_requires_auth(client):
    rv = client.get("/api/songs/search?q=test")
    assert rv.status_code == 401


def test_search_songs_requires_query(client):
    rv = client.get("/api/songs/search", headers=auth_header())
    assert rv.status_code == 400


def test_get_songs_empty(client):
    rv = client.get("/api/songs", headers=auth_header())
    assert rv.status_code == 200
    data = rv.get_json()
    assert data["songs"] == []


def test_post_song_manual(client):
    """Create a song without a genius_id (manual entry)."""
    rv = client.post(
        "/api/songs",
        json={"title": "Test Song", "artist": "Test Artist"},
        headers=auth_header(),
    )
    assert rv.status_code == 201
    data = rv.get_json()
    assert data["title"] == "Test Song"
    assert data["artist"] == "Test Artist"
    assert data["id"] is not None


def test_get_songs_returns_created_song(client):
    client.post(
        "/api/songs",
        json={"title": "Test Song", "artist": "Test Artist"},
        headers=auth_header(),
    )
    rv = client.get("/api/songs", headers=auth_header())
    data = rv.get_json()
    assert len(data["songs"]) == 1
    assert data["songs"][0]["title"] == "Test Song"


def test_put_song_updates_lyrics(client):
    rv = client.post(
        "/api/songs",
        json={"title": "Test Song", "artist": "Test Artist"},
        headers=auth_header(),
    )
    song_id = rv.get_json()["id"]
    rv = client.put(
        f"/api/songs/{song_id}",
        json={"lyrics": "Hello world lyrics", "lyrics_source": "manual"},
        headers=auth_header(),
    )
    assert rv.status_code == 200
    assert rv.get_json()["lyrics"] == "Hello world lyrics"


def test_post_song_occurrence(client):
    rv = client.post(
        "/api/songs",
        json={"title": "Test Song", "artist": "Test Artist"},
        headers=auth_header(),
    )
    song_id = rv.get_json()["id"]
    rv = client.post(
        f"/api/songs/{song_id}/occurrences",
        json={"timestamp": "2026-04-18T14:30:00Z", "source": "journal"},
        headers=auth_header(),
    )
    assert rv.status_code == 201
    assert rv.get_json()["song_id"] == song_id


def test_get_songs_includes_occurrence_count(client):
    rv = client.post(
        "/api/songs",
        json={"title": "Test Song", "artist": "Test Artist"},
        headers=auth_header(),
    )
    song_id = rv.get_json()["id"]
    client.post(
        f"/api/songs/{song_id}/occurrences",
        json={"timestamp": "2026-04-18T14:30:00Z", "source": "standalone"},
        headers=auth_header(),
    )
    rv = client.get("/api/songs", headers=auth_header())
    songs = rv.get_json()["songs"]
    assert songs[0]["occurrence_count"] == 1


def test_sync_with_songs(client):
    """Songs and song_occurrences in sync payload are upserted."""
    payload = {
        "syncType": "full",
        "exportDate": "2026-04-18T12:00:00Z",
        "songs": [
            {
                "serverId": None,
                "title": "Everybody Hurts",
                "artist": "R.E.M.",
                "album": "Automatic for the People",
                "geniusId": 4535,
                "lyrics": "When your day is long...",
                "lyricsSource": "manual",
                "updatedAt": "2026-04-18T15:00:00Z",
            }
        ],
        "songOccurrences": [
            {
                "songGeniusId": 4535,
                "timestamp": "2026-04-18T14:30:00Z",
                "source": "journal",
                "anxietyEntryTimestamp": None,
            }
        ],
    }
    rv = client.post("/api/sync", json=payload, headers=auth_header())
    assert rv.status_code == 200
    data = rv.get_json()
    assert data["counts"]["songs"] == 1
    assert data["counts"]["song_occurrences"] == 1


def test_sync_songs_upsert_by_genius_id(client):
    """Syncing a song twice with same genius_id updates rather than duplicates."""
    song = {
        "title": "Everybody Hurts",
        "artist": "R.E.M.",
        "geniusId": 4535,
        "updatedAt": "2026-04-18T15:00:00Z",
    }
    payload1 = {"syncType": "full", "songs": [song]}
    client.post("/api/sync", json=payload1, headers=auth_header())

    song["lyrics"] = "Updated lyrics"
    song["updatedAt"] = "2026-04-19T10:00:00Z"
    payload2 = {"syncType": "incremental", "songs": [song]}
    client.post("/api/sync", json=payload2, headers=auth_header())

    rv = client.get("/api/songs", headers=auth_header())
    songs = rv.get_json()["songs"]
    assert len(songs) == 1
    assert songs[0]["lyrics"] == "Updated lyrics"


# ---------------------------------------------------------------------------
# SECRET_KEY enforcement
# ---------------------------------------------------------------------------


def test_create_app_raises_without_secret_key(monkeypatch):
    """create_app raises RuntimeError when SECRET_KEY is missing and TESTING is false."""
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(RuntimeError, match="SECRET_KEY"):
        create_app({"DATABASE_URL": DATABASE_URL})


def test_create_app_uses_test_default_when_testing(monkeypatch):
    """create_app falls back to a test-only SECRET_KEY when TESTING is True."""
    monkeypatch.delenv("SECRET_KEY", raising=False)
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    assert app.config["SECRET_KEY"] == "test-secret-key"


def test_create_app_honors_secret_key_from_test_config(monkeypatch):
    """create_app honors SECRET_KEY passed via test_config when env var is unset."""
    monkeypatch.delenv("SECRET_KEY", raising=False)
    app = create_app({"TESTING": True, "SECRET_KEY": "custom-key", "DATABASE_URL": DATABASE_URL})
    assert app.config["SECRET_KEY"] == "custom-key"


def test_create_app_env_var_overrides_test_config(monkeypatch):
    """Environment SECRET_KEY takes precedence over test_config SECRET_KEY."""
    monkeypatch.setenv("SECRET_KEY", "env-key")
    app = create_app({"TESTING": True, "SECRET_KEY": "config-key", "DATABASE_URL": DATABASE_URL})
    assert app.config["SECRET_KEY"] == "env-key"


# ---------------------------------------------------------------------------
# format_analysis template filter
# ---------------------------------------------------------------------------


class TestFormatAnalysisFilter:
    """Tests for the format_analysis Jinja2 template filter."""

    def test_plain_text_unchanged(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            assert str(f("Hello world")) == "Hello world"

    def test_markdown_bold_converted(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            result = str(f("**Anxiety trajectory.** The data shows..."))
            assert "<strong>Anxiety trajectory.</strong>" in result
            assert "**" not in result

    def test_cite_tags_converted_to_quotes(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            text = ('The guideline states: <cite index="11-21">'
                    'Physical dependence is distinct from SUD.</cite> This matters.')
            result = str(f(text))
            assert "<q>Physical dependence is distinct from SUD.</q>" in result
            assert "&lt;cite" not in result

    def test_html_escaped(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            result = str(f("<script>alert('xss')</script>"))
            assert "<script>" not in result
            assert "&lt;script&gt;" in result

    def test_none_passthrough(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            assert f(None) is None

    def test_empty_string_passthrough(self, app):
        with app.app_context():
            f = app.jinja_env.filters["format_analysis"]
            assert f("") == ""


# ---------------------------------------------------------------------------
# Polar H10 sensor_sessions + hrv_readings sync (PR 130, migration 0005)
# ---------------------------------------------------------------------------


def _polar_session_payload(session_id, **overrides):
    base = {
        "id": session_id,
        "source": "polar_h10",
        "startTime": "2026-05-11T03:00:00Z",
        "endTime": "2026-05-11T10:30:00Z",
        "batteryAtStart": 78,
        "interruptionCount": 2,
        "summaryJSON": {"rmssdMean": 46.7, "rrCount": 28912, "durationSec": 27000},
    }
    base.update(overrides)
    return base


def _hrv_reading_payload(reading_id, session_id, **overrides):
    base = {
        "id": reading_id,
        "sessionId": session_id,
        "timestamp": "2026-05-11T03:01:00Z",
        "rmssd": 42.0,
        "sdnn": 50.0,
        "pnn50": 10.0,
        "lfPower": 120.5,
        "hfPower": 80.2,
        "lfHfRatio": 1.5,
        "source": "polar_h10",
    }
    base.update(overrides)
    return base


def test_sync_sensor_session_inserts_row(client, app):
    session_id = "11111111-1111-1111-1111-111111111111"
    resp = client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    assert resp.status_code == 200
    assert resp.get_json()["counts"]["sensor_sessions"] == 1

    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "SELECT source, battery_at_start, interruption_count, summary_json FROM sensor_sessions WHERE id = %s",
            (session_id,),
        )
        row = cur.fetchone()
        assert row is not None
        assert row[0] == "polar_h10"
        assert row[1] == 78
        assert row[2] == 2
        # summary_json round-trips through JSONB as a dict
        assert row[3]["rmssdMean"] == 46.7


def test_sync_sensor_session_accepts_summary_json_as_string(client, app):
    """iOS `SensorSession.summaryJSON` is `String?` (a pre-encoded JSON
    string). A naive Phase-3b client would send it as a string rather than
    a decoded dict — the server must accept both shapes and store a real
    JSONB object either way, so `summary_json->>'rmssdMean'` lookups work
    regardless of which client variant produced the row."""
    session_id = "21111111-1111-1111-1111-111111111111"
    payload = _polar_session_payload(session_id)
    # Pre-encode as iOS would naively send it (String? round-tripped over JSON).
    payload["summaryJSON"] = json.dumps({"rmssdMean": 41.2, "rrCount": 27000})
    resp = client.post("/api/sync", json={"sensorSessions": [payload]}, headers=auth_header())
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT summary_json FROM sensor_sessions WHERE id = %s", (session_id,))
        stored = cur.fetchone()[0]
        # If the server had double-encoded the string, `stored` would be a
        # JSON string ("{...}") and dict access would raise. We want a dict.
        assert isinstance(stored, dict)
        assert stored["rmssdMean"] == 41.2
        # Indexed lookup via Postgres operator must also work.
        cur.execute(
            "SELECT (summary_json->>'rmssdMean')::float FROM sensor_sessions WHERE id = %s",
            (session_id,),
        )
        assert cur.fetchone()[0] == 41.2


def test_sync_sensor_session_drops_malformed_summary_json_string(client, app):
    """A malformed JSON string in `summaryJSON` shouldn't poison the upsert
    batch — drop it (the column is nullable) and let the rest of the row
    land. Same precedent as other importer fixes that don't fail closed
    on one bad field."""
    session_id = "21222222-2222-2222-2222-222222222222"
    payload = _polar_session_payload(session_id)
    payload["summaryJSON"] = "this is not json {{{"
    resp = client.post("/api/sync", json={"sensorSessions": [payload]}, headers=auth_header())
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT summary_json FROM sensor_sessions WHERE id = %s", (session_id,))
        assert cur.fetchone()[0] is None


def test_sync_sensor_session_is_idempotent(client, app):
    session_id = "22222222-2222-2222-2222-222222222222"
    payload = _polar_session_payload(session_id)
    client.post("/api/sync", json={"sensorSessions": [payload]}, headers=auth_header())
    # Repeat with an updated summary — should update in place, not insert.
    payload["summaryJSON"] = {"rmssdMean": 50.0, "rrCount": 31000}
    client.post("/api/sync", json={"sensorSessions": [payload]}, headers=auth_header())

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT COUNT(*), MAX((summary_json->>'rmssdMean')::float) FROM sensor_sessions WHERE id = %s",
                    (session_id,))
        count, max_rmssd = cur.fetchone()
        assert count == 1
        assert max_rmssd == 50.0


def test_sync_sensor_session_partial_update_preserves_existing_fields(client, app):
    """Replay with only the start row (no summary) keeps the previous summary."""
    session_id = "33333333-3333-3333-3333-333333333333"
    # First sync: full row with summary.
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    # Second sync: only start row (summary omitted).
    partial = {
        "id": session_id,
        "source": "polar_h10",
        "startTime": "2026-05-11T03:00:00Z",
        "interruptionCount": 2,
    }
    client.post(
        "/api/sync",
        json={"sensorSessions": [partial]},
        headers=auth_header(),
    )

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute(
            "SELECT end_time, battery_at_start, summary_json FROM sensor_sessions WHERE id = %s",
            (session_id,),
        )
        end_time, battery, summary = cur.fetchone()
        # Original end_time, battery, summary should all survive the
        # partial replay via COALESCE.
        assert end_time is not None
        assert battery == 78
        assert summary["rmssdMean"] == 46.7


def test_sync_sensor_session_stale_replay_does_not_regress_interruption_count(client, app):
    """A payload built client-side BEFORE a finalize can land AFTER the
    finalized row (retry queues, drain-loop edge cases). end_time and
    summary_json survive via COALESCE, but interruption_count is never
    NULL — it needs GREATEST so the stale-low value can't overwrite the
    finalized count. Counts only grow over a session's life, so taking
    the max keeps replays idempotent."""
    session_id = "f6a3b2c1-d4e5-4f6a-8b7c-0e1f2a3b4c5d"
    # Finalized row arrives first: 3 interruptions.
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id, interruptionCount=3)]},
        headers=auth_header(),
    )
    # Stale pre-finalize payload replays with a lower count.
    stale = _polar_session_payload(session_id, interruptionCount=1)
    del stale["endTime"]
    resp = client.post("/api/sync", json={"sensorSessions": [stale]}, headers=auth_header())
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute(
            "SELECT interruption_count, end_time FROM sensor_sessions WHERE id = %s",
            (session_id,),
        )
        count, end_time = cur.fetchone()
        assert count == 3  # not regressed to 1
        assert end_time is not None  # COALESCE keeps the finalized end_time


def test_sync_hrv_readings_after_session(client, app):
    session_id = "44444444-4444-4444-4444-444444444444"
    reading_id = "55555555-5555-5555-5555-555555555555"
    resp = client.post(
        "/api/sync",
        json={
            "sensorSessions": [_polar_session_payload(session_id)],
            "hrvReadings": [_hrv_reading_payload(reading_id, session_id)],
        },
        headers=auth_header(),
    )
    assert resp.status_code == 200
    counts = resp.get_json()["counts"]
    assert counts["sensor_sessions"] == 1
    assert counts["hrv_readings"] == 1

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT rmssd, lf_power FROM hrv_readings WHERE id = %s", (reading_id,))
        rmssd, lf = cur.fetchone()
        assert rmssd == 42.0
        assert lf == 120.5


def test_sync_hrv_reading_with_null_frequency_domain(client, app):
    """Per-minute windows with <30 RR intervals have time-domain only —
    LF/HF/ratio must be allowed to be null."""
    session_id = "66666666-6666-6666-6666-666666666666"
    reading_id = "77777777-7777-7777-7777-777777777777"
    sparse = _hrv_reading_payload(
        reading_id, session_id,
        lfPower=None, hfPower=None, lfHfRatio=None,
    )
    resp = client.post(
        "/api/sync",
        json={
            "sensorSessions": [_polar_session_payload(session_id)],
            "hrvReadings": [sparse],
        },
        headers=auth_header(),
    )
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute(
            "SELECT lf_power, hf_power, lf_hf_ratio FROM hrv_readings WHERE id = %s",
            (reading_id,),
        )
        lf, hf, ratio = cur.fetchone()
        assert lf is None and hf is None and ratio is None


def test_hrv_reading_cascade_deletes_with_session(client, app):
    session_id = "88888888-8888-8888-8888-888888888888"
    reading_id = "99999999-9999-9999-9999-999999999999"
    client.post(
        "/api/sync",
        json={
            "sensorSessions": [_polar_session_payload(session_id)],
            "hrvReadings": [_hrv_reading_payload(reading_id, session_id)],
        },
        headers=auth_header(),
    )

    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute("DELETE FROM sensor_sessions WHERE id = %s", (session_id,))
        db.commit()
        cur.execute("SELECT COUNT(*) FROM hrv_readings WHERE id = %s", (reading_id,))
        assert cur.fetchone()[0] == 0


def test_rr_archive_upload_attaches_bytes_to_session(client, app):
    session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    archive_bytes = b"\x1f\x8b\x08\x00" + (b"\x00" * 100)  # plausible gzip-magic prefix
    resp = client.post(
        f"/api/sensor_sessions/{session_id}/rr_archive",
        data=archive_bytes,
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 200, resp.get_data(as_text=True)
    assert resp.get_json()["bytes"] == len(archive_bytes)

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT rr_archive FROM sensor_sessions WHERE id = %s", (session_id,))
        # psycopg2 returns BYTEA as memoryview by default.
        archive = bytes(cur.fetchone()[0])
        assert archive == archive_bytes


def test_rr_archive_upload_404_for_unknown_session(client):
    resp = client.post(
        "/api/sensor_sessions/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/rr_archive",
        data=b"junk",
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 404


def test_rr_archive_upload_400_for_invalid_session_id(client):
    resp = client.post(
        "/api/sensor_sessions/not-a-uuid/rr_archive",
        data=b"junk",
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 400


def test_rr_archive_upload_400_for_empty_payload(client):
    """Empty body must produce 400, but only when the target session exists.
    Without the seeded session the endpoint would correctly return 404 first
    (resource-existence beats payload validation), which would conflate two
    distinct failure modes."""
    session_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    resp = client.post(
        f"/api/sensor_sessions/{session_id}/rr_archive",
        data=b"",
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 400


def test_rr_archive_upload_404_beats_empty_payload(client):
    """Resource-existence check must run before payload validation: a POST
    to an unknown session_id with an empty body returns 404, not 400."""
    resp = client.post(
        "/api/sensor_sessions/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/rr_archive",
        data=b"",
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 404


def test_rr_archive_upload_413_for_oversize_payload(client, app):
    """Payloads exceeding the 5 MB cap must be rejected with 413 and not
    written to the row. Insert a session first so the failure can't be
    confused with a 404."""
    session_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    client.post(
        "/api/sync",
        json={"sensorSessions": [_polar_session_payload(session_id)]},
        headers=auth_header(),
    )
    # 6 MB > the 5 MB cap.
    oversize = b"\x00" * (6 * 1024 * 1024)
    resp = client.post(
        f"/api/sensor_sessions/{session_id}/rr_archive",
        data=oversize,
        headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 413

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT rr_archive FROM sensor_sessions WHERE id = %s", (session_id,))
        # rr_archive should still be NULL — the oversize upload didn't land.
        assert cur.fetchone()[0] is None


# ---------------------------------------------------------------------------
# Song occurrence skip accounting (F-038)
# ---------------------------------------------------------------------------


def test_sync_unlinkable_song_occurrence_counted_as_skipped(client, app, caplog):
    """An occurrence that can't be linked to any song must be reported as
    skipped, not silently folded into the upserted count: the iOS client
    advances its sync cursor on a 200 response, so a miscounted occurrence
    would never be re-sent and would be lost with no signal anywhere."""
    payload = {
        "songs": [
            {
                "title": "Everybody Hurts",
                "artist": "R.E.M.",
                "geniusId": 4535,
                "updatedAt": "2026-04-18T15:00:00Z",
            }
        ],
        "songOccurrences": [
            # Linkable — matches the song above by genius_id.
            {"songGeniusId": 4535, "timestamp": "2026-04-18T14:30:00Z", "source": "journal"},
            # Unlinkable — unknown genius_id and no songServerId (e.g. a
            # manually-added song created offline whose serverId the client
            # never learned).
            {"songGeniusId": 99999, "timestamp": "2026-04-18T15:45:00Z", "source": "journal"},
        ],
    }
    with caplog.at_level(logging.WARNING):
        resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200  # a skip must NOT fail the whole sync
    counts = resp.get_json()["counts"]
    assert counts["song_occurrences"] == 1
    assert counts["song_occurrences_skipped"] == 1

    # A server-side warning names the occurrence by timestamp (never notes).
    warning = next(
        (r for r in caplog.records if "unlinkable song occurrence" in r.getMessage()), None
    )
    assert warning is not None
    assert "2026-04-18T15:45:00Z" in warning.getMessage()

    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        # Only the linkable occurrence landed.
        cur.execute("SELECT COUNT(*) FROM song_occurrences")
        assert cur.fetchone()[0] == 1
        # The skip count is also recorded in the sync_log counts JSON.
        cur.execute("SELECT record_counts FROM sync_log ORDER BY received_at DESC LIMIT 1")
        record_counts = cur.fetchone()[0]
        assert record_counts["song_occurrences"] == 1
        assert record_counts["song_occurrences_skipped"] == 1


def test_sync_song_occurrences_no_skipped_key_when_all_link(client):
    """The skipped key is additive and only present when something was skipped."""
    payload = {
        "songs": [
            {
                "title": "Everybody Hurts",
                "artist": "R.E.M.",
                "geniusId": 4535,
                "updatedAt": "2026-04-18T15:00:00Z",
            }
        ],
        "songOccurrences": [
            {"songGeniusId": 4535, "timestamp": "2026-04-18T14:30:00Z", "source": "journal"},
        ],
    }
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200
    counts = resp.get_json()["counts"]
    assert counts["song_occurrences"] == 1
    assert "song_occurrences_skipped" not in counts


# ---------------------------------------------------------------------------
# Nullable CPAP AHI (F-068)
# ---------------------------------------------------------------------------


def _cpap_payload(**overrides):
    base = {
        "date": "2025-03-21", "ahi": 1.8, "totalUsageMinutes": 400,
        "leakRate95th": 4.2, "pressureMin": 6.0, "pressureMax": 12.0, "pressureMean": 9.0,
        "obstructiveEvents": 2, "centralEvents": 1, "hypopneaEvents": 1, "importSource": "sd_card",
    }
    base.update(overrides)
    return base


def test_sync_cpap_session_without_ahi_stores_null(client, app):
    """A session with no measured AHI (EDF-only provenance) stores NULL,
    which /api/data exports as JSON null — not a fabricated 0.0."""
    payload = {"cpapSessions": [_cpap_payload(importSource="edf")]}
    del payload["cpapSessions"][0]["ahi"]
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2025-03-21'")
        assert cur.fetchone()[0] is None

    resp = client.get("/api/data/cpapSessions", headers=auth_header())
    sessions = resp.get_json()["cpapSessions"]
    assert len(sessions) == 1
    assert sessions[0]["ahi"] is None


def test_sync_cpap_null_ahi_does_not_clobber_measured_value(client, app):
    """A later null-AHI upsert for the same date must preserve a previously
    measured AHI (COALESCE keeps the existing value)."""
    resp = client.post(
        "/api/sync", json={"cpapSessions": [_cpap_payload(ahi=2.4)]}, headers=auth_header()
    )
    assert resp.status_code == 200
    payload = {"cpapSessions": [_cpap_payload()]}
    del payload["cpapSessions"][0]["ahi"]
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    assert resp.status_code == 200

    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2025-03-21'")
        assert cur.fetchone()[0] == 2.4


def test_sync_cpap_measured_ahi_still_stored(client, app):
    """Regression guard: the nullable-ahi change must not affect sessions
    that carry a real measured AHI."""
    resp = client.post(
        "/api/sync", json={"cpapSessions": [_cpap_payload(ahi=0.0)]}, headers=auth_header()
    )
    assert resp.status_code == 200
    with app.app_context():
        cur = app.get_db().cursor()
        cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2025-03-21'")
        # A measured 0.0 is a real clinical value and must round-trip as 0.0.
        assert cur.fetchone()[0] == 0.0
