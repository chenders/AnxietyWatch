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
def app(_init_db, monkeypatch):
    monkeypatch.setenv("ADMIN_PASSWORD", "test")
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
    assert row["gender"] == "male"
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
    assert row["gender"] == "non_binary"


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


from unittest.mock import patch, MagicMock  # noqa: E402


def _mock_claude_response(text):
    """Create a mock Anthropic message response."""
    mock_msg = MagicMock()
    mock_msg.content = [MagicMock(text=text)]
    mock_msg.usage.input_tokens = 100
    mock_msg.usage.output_tokens = 50
    return mock_msg


def test_refine_medical_history(client):
    """POST /admin/patient-profile/refine returns structured history."""
    _login(client)
    structured = "## Diagnoses\n- GAD since 2018\n\n## Follow-up Questions\n1. Any hospitalizations?"

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(structured)

        resp = client.post("/admin/patient-profile/refine", json={
            "medical_history_raw": "I have GAD diagnosed in 2018",
        })

    assert resp.status_code == 200
    data = resp.get_json()
    assert "structured" in data
    assert "GAD" in data["structured"]


def test_refine_medical_history_finalize(client):
    """POST /admin/patient-profile/refine with answers finalizes the structured history."""
    _login(client)
    final = "## Diagnoses\n- GAD since 2018, no hospitalizations"

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(final)

        resp = client.post("/admin/patient-profile/refine", json={
            "medical_history_raw": "I have GAD diagnosed in 2018",
            "structured_draft": "## Diagnoses\n- GAD\n\n## Questions\n1. Hospitalizations?",
            "answers": "No hospitalizations ever",
        })

    assert resp.status_code == 200
    data = resp.get_json()
    assert "structured" in data


def test_generate_profile_summary(client, app):
    """POST /admin/patient-profile/generate-summary returns a summary."""
    _login(client)
    # Insert a profile first
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO patient_profile (name, date_of_birth, gender, medical_history_structured) "
            "VALUES ('Test User', '1992-03-15', 'Male', 'GAD since 2018')"
        )
        cur.execute(
            "INSERT INTO medication_definitions (name, default_dose_mg, category, is_active) "
            "VALUES ('Clonazepam', 1.0, 'benzodiazepine', TRUE)"
        )
        db.commit()

    summary = "Male patient, born 1992. GAD since 2018. Takes Clonazepam 1mg."

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(summary)

        resp = client.post("/admin/patient-profile/generate-summary")

    assert resp.status_code == 200
    data = resp.get_json()
    assert "summary" in data
    assert "Clonazepam" in data["summary"]


def test_refine_requires_api_key(client):
    """Refinement returns 400 if ANTHROPIC_API_KEY is not set."""
    _login(client)
    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}, clear=False):
        resp = client.post("/admin/patient-profile/refine", json={
            "medical_history_raw": "test",
        })
    assert resp.status_code == 400


def test_psychiatrist_profile_get_empty(client):
    """GET /admin/psychiatrist-profile returns 200 with empty form."""
    _login(client)
    resp = client.get("/admin/psychiatrist-profile")
    assert resp.status_code == 200
    assert b"Psychiatrist Profile" in resp.data


def test_psychiatrist_profile_save(client, app):
    """POST /admin/psychiatrist-profile saves name and location."""
    _login(client)
    resp = client.post("/admin/psychiatrist-profile", data={
        "name": "Jane Smith MD",
        "location": "Portland, OR",
    }, follow_redirects=True)
    assert resp.status_code == 200

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM psychiatrist_profile LIMIT 1")
        row = cur.fetchone()
    assert row["name"] == "Jane Smith MD"
    assert row["location"] == "Portland, OR"


def test_psychiatrist_profile_update_existing(client, app):
    """POST /admin/psychiatrist-profile updates existing row."""
    _login(client)
    client.post("/admin/psychiatrist-profile", data={
        "name": "Jane Smith MD",
        "location": "Portland, OR",
    })
    client.post("/admin/psychiatrist-profile", data={
        "name": "Jane Smith MD",
        "location": "Seattle, WA",
        "profile_summary": "Board-certified psychiatrist in Seattle",
    })

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT count(*) AS cnt FROM psychiatrist_profile")
        assert cur.fetchone()["cnt"] == 1
        cur.execute("SELECT * FROM psychiatrist_profile LIMIT 1")
        row = cur.fetchone()
    assert row["location"] == "Seattle, WA"
    assert row["profile_summary"] == "Board-certified psychiatrist in Seattle"


def test_psychiatrist_research(client):
    """POST /admin/psychiatrist-profile/research returns structured results."""
    _login(client)
    research_json = json.dumps({
        "credentials": "MD, Board Certified Psychiatry",
        "specialty": "Anxiety disorders",
        "publications": [],
        "disciplinary_history": "None found",
    })

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(research_json)

        resp = client.post("/admin/psychiatrist-profile/research", json={
            "name": "Jane Smith MD",
            "location": "Portland, OR",
        })

    assert resp.status_code == 200
    data = resp.get_json()
    assert "research_result" in data

    # Verify the Anthropic API was called with the correct web_search tool definition
    call_kwargs = mock_client.messages.create.call_args[1]
    assert call_kwargs["tools"] == [{"type": "web_search_20250305", "name": "web_search"}]


def test_psychiatrist_research_repairs_fenced_json(client, app):
    """Web search responses with fenced JSON and citation newlines are repaired."""
    _login(client)
    # Simulate Claude's web search response: preamble, fenced JSON with literal
    # newlines inside string values (from citation text blocks), and caveats after.
    fenced_response = (
        "I'll research this psychiatrist. Let me search.\n\n"
        '```json\n'
        '{\n'
        '  "credentials": "\nMD, Board Certified\n; \nlicensed in Oregon\n",\n'
        '  "specialty": "Anxiety disorders",\n'
        '  "publications": [{"title": "\nSome\npaper\n", "year": 2020}],\n'
        '  "sources": ["https://example.com"]\n'
        '}\n'
        '```\n\n'
        "**Caveats:** Verify with the medical board."
    )

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(fenced_response)

        resp = client.post("/admin/psychiatrist-profile/research", json={
            "name": "Jane Smith MD",
            "location": "Portland, OR",
        })

    assert resp.status_code == 200
    data = resp.get_json()
    result = data["research_result"]

    # JSON was parsed (not raw_response fallback)
    assert "raw_response" not in result
    # Citation newlines cleaned from string values
    assert "\n" not in result["credentials"]
    assert "MD, Board Certified" in result["credentials"]
    # Nested dict in list was also cleaned
    assert "\n" not in result["publications"][0]["title"]
    assert result["publications"][0]["title"] == "Some paper"

    # Verify it was saved to DB
    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT research_result FROM psychiatrist_profile LIMIT 1")
        row = cur.fetchone()
        assert row["research_result"]["credentials"] == result["credentials"]


def test_psychiatrist_generate_summary_no_api_key(client):
    """POST /admin/psychiatrist-profile/generate-summary returns 400 without API key."""
    _login(client)
    with patch.dict(os.environ, {}, clear=False):
        os.environ.pop("ANTHROPIC_API_KEY", None)
        resp = client.post("/admin/psychiatrist-profile/generate-summary")
    assert resp.status_code == 400


def test_psychiatrist_generate_summary_no_profile(client):
    """POST /admin/psychiatrist-profile/generate-summary returns 404 without a profile."""
    _login(client)
    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
        resp = client.post("/admin/psychiatrist-profile/generate-summary")
    assert resp.status_code == 404


def test_psychiatrist_generate_summary_no_research(client):
    """POST /admin/psychiatrist-profile/generate-summary returns 400 without research results."""
    _login(client)
    client.post("/admin/psychiatrist-profile", data={
        "name": "Jane Smith MD",
        "location": "Portland, OR",
    })
    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
        resp = client.post("/admin/psychiatrist-profile/generate-summary")
    assert resp.status_code == 400
    assert "research" in resp.get_json()["error"].lower()


def test_psychiatrist_generate_summary_success(client, app):
    """POST /admin/psychiatrist-profile/generate-summary synthesizes research into summary."""
    _login(client)
    # Create profile with research results
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO psychiatrist_profile (name, location, research_result, researched_at) "
            "VALUES (%s, %s, %s, NOW())",
            ("Jane Smith MD", "Portland, OR", json.dumps({
                "credentials": "MD, Board Certified Psychiatry",
                "specialty": "Anxiety disorders",
            })),
        )
        db.commit()

    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}), \
            patch("admin.anthropic") as mock_anthropic:
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_client.messages.create.return_value = _mock_claude_response(
            "Dr. Jane Smith is a board-certified psychiatrist specializing in anxiety disorders."
        )
        resp = client.post("/admin/psychiatrist-profile/generate-summary")

    assert resp.status_code == 200
    data = resp.get_json()
    assert "summary" in data
    assert "Jane Smith" in data["summary"]

    # Verify the prompt included research data
    call_kwargs = mock_client.messages.create.call_args[1]
    assert "Credentials" in call_kwargs["messages"][0]["content"]
    assert "Board Certified" in call_kwargs["messages"][0]["content"]


def test_build_prompt_without_patient_context(app):
    """build_prompt with no patient_context omits the section entirely."""
    with app.app_context():
        from analysis import build_prompt
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )
    assert "Patient Context" not in system


def test_build_prompt_with_patient_context(app):
    """build_prompt with patient_context includes Patient Context section."""
    with app.app_context():
        from analysis import build_prompt
        patient_context = {
            "patient_name": "Test User",
            "patient_summary": "Male, 34, GAD since 2018. Takes Clonazepam 1mg.",
            "psychiatrist_summary": "Board-certified psychiatrist specializing in anxiety.",
            "active_conflict": None,
        }
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
            patient_context=patient_context,
        )
    assert "## Patient Context" in system
    assert "Test User" in system
    assert "GAD since 2018" in system
    assert "Board-certified psychiatrist" in system


def test_build_prompt_with_active_conflict(app):
    """build_prompt with active conflict includes conflict note."""
    with app.app_context():
        from analysis import build_prompt
        patient_context = {
            "patient_name": "Test User",
            "patient_summary": "Male, 34, GAD since 2018.",
            "psychiatrist_summary": "Anxiety specialist.",
            "active_conflict": "Disagreement about medication dosage reduction.",
        }
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
            patient_context=patient_context,
        )
    assert "Active conflict" in system
    assert "medication dosage reduction" in system


def test_build_prompt_patient_only_no_psychiatrist(app):
    """build_prompt with patient but no psychiatrist summary omits psychiatrist line."""
    with app.app_context():
        from analysis import build_prompt
        patient_context = {
            "patient_name": None,
            "patient_summary": "Male, 34.",
            "psychiatrist_summary": None,
            "active_conflict": None,
        }
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
            patient_context=patient_context,
        )
    assert "## Patient Context" in system
    assert "Psychiatrist:" not in system


def test_sync_demographics_creates_patient_profile(client, app):
    """Sync payload with demographics creates patient_profile row."""
    resp = client.post("/api/sync", json={
        "syncType": "full",
        "clientVersion": "1.0",
        "deviceName": "Test iPhone",
        "demographics": {
            "dateOfBirth": "1992-03-15",
            "biologicalSex": "male",
        },
        "anxietyEntries": [],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
        "pharmacies": [],
        "prescriptions": [],
        "pharmacyCallLogs": [],
    }, headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"})

    assert resp.status_code == 200

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM patient_profile LIMIT 1")
        row = cur.fetchone()
    assert row is not None
    assert str(row["date_of_birth"]) == "1992-03-15"
    assert row["gender"] == "male"


def test_sync_demographics_does_not_overwrite_manual_values(client, app):
    """Sync demographics doesn't overwrite manually-entered profile values."""
    # Create manual profile first
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO patient_profile (name, date_of_birth, gender) "
            "VALUES ('Manual Name', '1990-01-01', 'Non-binary')"
        )
        db.commit()

    resp = client.post("/api/sync", json={
        "syncType": "full",
        "clientVersion": "1.0",
        "demographics": {
            "dateOfBirth": "1992-03-15",
            "biologicalSex": "male",
        },
        "anxietyEntries": [],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
        "pharmacies": [],
        "prescriptions": [],
        "pharmacyCallLogs": [],
    }, headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"})
    assert resp.status_code == 200

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM patient_profile LIMIT 1")
        row = cur.fetchone()
    # Should NOT be overwritten
    assert str(row["date_of_birth"]) == "1990-01-01"
    assert row["gender"] == "Non-binary"
    assert row["name"] == "Manual Name"


def test_sync_demographics_fills_null_fields(client, app):
    """Sync demographics fills NULL fields but not populated ones."""
    # Create profile with name but no DOB/gender
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO patient_profile (name) VALUES ('Test User')"
        )
        db.commit()

    client.post("/api/sync", json={
        "syncType": "full",
        "clientVersion": "1.0",
        "demographics": {
            "dateOfBirth": "1992-03-15",
            "biologicalSex": "female",
        },
        "anxietyEntries": [],
        "medicationDefinitions": [],
        "medicationDoses": [],
        "cpapSessions": [],
        "healthSnapshots": [],
        "barometricReadings": [],
        "pharmacies": [],
        "prescriptions": [],
        "pharmacyCallLogs": [],
    }, headers={"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"})

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM patient_profile LIMIT 1")
        row = cur.fetchone()
    assert row["name"] == "Test User"  # preserved
    assert str(row["date_of_birth"]) == "1992-03-15"  # filled
    assert row["gender"] == "female"  # filled


def test_create_pending_analysis_reads_patient_context(app):
    """_create_pending_analysis reads patient_profile and injects context into prompt."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO patient_profile (name, profile_summary) "
            "VALUES ('Test User', 'Test patient summary for prompt injection')"
        )
        # Insert some data so the analysis has something to work with
        cur.execute(
            "INSERT INTO anxiety_entries (timestamp, severity, notes, tags) "
            "VALUES ('2026-01-10 12:00:00+00', 5, 'test', '[]')"
        )
        db.commit()

        from analysis import _create_pending_analysis
        analysis_id, system_prompt, user_message = _create_pending_analysis(
            db, date(2026, 1, 10), date(2026, 1, 10),
        )

    assert "Patient Context" in system_prompt
    assert "Test User" in system_prompt
    assert "Test patient summary" in system_prompt
