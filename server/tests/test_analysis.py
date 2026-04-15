"""Tests for the AI analysis engine."""

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


def test_parse_response_valid():
    """parse_response extracts structured data from Claude response."""
    from analysis import parse_response

    raw_response = {
        "content": [
            {
                "type": "text",
                "text": json.dumps({
                    "summary": "Test summary paragraph.",
                    "trend_direction": "improving",
                    "insights": [
                        {
                            "category": "correlation",
                            "severity": "high",
                            "title": "HRV predicts anxiety",
                            "detail": "When HRV drops below 40...",
                            "confidence": 0.85,
                            "confidence_explanation": "Strong effect size...",
                            "supporting_data": {"r": -0.72},
                        }
                    ],
                }),
            }
        ],
        "usage": {"input_tokens": 48000, "output_tokens": 3400},
    }
    result = parse_response(raw_response)

    assert result["summary"] == "Test summary paragraph."
    assert result["trend_direction"] == "improving"
    assert len(result["insights"]) == 1
    assert result["insights"][0]["title"] == "HRV predicts anxiety"
    assert result["insights"][0]["confidence"] == 0.85
    assert result["tokens_in"] == 48000
    assert result["tokens_out"] == 3400


def test_parse_response_invalid_json():
    """parse_response raises ValueError for non-JSON response."""
    from analysis import parse_response

    raw_response = {
        "content": [{"type": "text", "text": "This is not JSON"}],
        "usage": {"input_tokens": 100, "output_tokens": 50},
    }
    with pytest.raises(ValueError, match="Failed to parse"):
        parse_response(raw_response)


def test_parse_response_missing_fields():
    """parse_response handles response missing optional fields."""
    from analysis import parse_response

    raw_response = {
        "content": [
            {
                "type": "text",
                "text": json.dumps({
                    "summary": "Short summary.",
                    "trend_direction": "stable",
                    "insights": [],
                }),
            }
        ],
        "usage": {"input_tokens": 1000, "output_tokens": 200},
    }
    result = parse_response(raw_response)
    assert result["summary"] == "Short summary."
    assert result["insights"] == []


def test_parse_response_code_fenced():
    """parse_response strips markdown code fences wrapping JSON."""
    from analysis import parse_response

    inner = json.dumps({
        "summary": "Fenced summary.",
        "trend_direction": "stable",
        "insights": [],
    })
    raw_response = {
        "content": [{"type": "text", "text": f"```json\n{inner}\n```"}],
        "usage": {"input_tokens": 100, "output_tokens": 50},
    }
    result = parse_response(raw_response)
    assert result["summary"] == "Fenced summary."
    assert result["trend_direction"] == "stable"
    assert result["insights"] == []


# ---------------------------------------------------------------------------
# Tests for run_analysis, get_analysis, list_analyses
# ---------------------------------------------------------------------------

from unittest.mock import patch, MagicMock  # noqa: E402


def _mock_anthropic_response():
    """Build a mock Anthropic API response."""
    mock_message = MagicMock()
    mock_message.content = [
        MagicMock(type="text", text=json.dumps({
            "summary": "Anxiety has been stable over this period.",
            "trend_direction": "stable",
            "insights": [
                {
                    "category": "correlation",
                    "severity": "medium",
                    "title": "HRV inversely correlates with severity",
                    "detail": "Lower HRV days show higher anxiety.",
                    "confidence": 0.7,
                    "confidence_explanation": "Moderate sample size.",
                    "supporting_data": {"r": -0.65},
                }
            ],
        }))
    ]
    mock_message.usage = MagicMock(input_tokens=5000, output_tokens=500)
    mock_message.model_dump.return_value = {
        "content": [{"type": "text", "text": mock_message.content[0].text}],
        "usage": {"input_tokens": 5000, "output_tokens": 500},
    }
    return mock_message


def test_run_analysis_stores_result(app):
    """run_analysis calls Claude and stores the result."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import run_analysis, get_analysis
        db = app.get_db()

        mock_client = MagicMock()
        mock_client.messages.create.return_value = _mock_anthropic_response()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            analysis_id = run_analysis(db, date(2026, 1, 10), date(2026, 1, 12))

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    assert result is not None
    assert result["status"] == "completed"
    assert result["summary"] == "Anxiety has been stable over this period."
    assert result["trend_direction"] == "stable"
    assert len(result["insights"]) == 1
    assert result["tokens_in"] == 5000
    assert result["tokens_out"] == 500
    assert result["request_payload"] is not None
    assert result["response_payload"] is not None


def test_run_analysis_handles_api_error(app):
    """run_analysis stores failed status on API error."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import run_analysis, get_analysis
        db = app.get_db()

        mock_client = MagicMock()
        mock_client.messages.create.side_effect = Exception("API timeout")

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            analysis_id = run_analysis(db, date(2026, 1, 10), date(2026, 1, 12))

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    assert result["status"] == "failed"
    assert "API timeout" in result["error_message"]


def test_list_analyses(app):
    """list_analyses returns all analyses newest first."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import run_analysis, list_analyses
        db = app.get_db()

        mock_client = MagicMock()
        mock_client.messages.create.return_value = _mock_anthropic_response()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            run_analysis(db, date(2026, 1, 10), date(2026, 1, 11))
            run_analysis(db, date(2026, 1, 11), date(2026, 1, 12))

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        analyses = list_analyses(cur)

    assert len(analyses) == 2
    assert analyses[0]["id"] > analyses[1]["id"]


# ---------------------------------------------------------------------------
# Admin route integration tests
# ---------------------------------------------------------------------------

ADMIN_PASSWORD = "test-admin-password"


@pytest.fixture()
def admin_client(app, monkeypatch):
    """Client with admin session."""
    app.config["SECRET_KEY"] = "test-secret"
    monkeypatch.setenv("ADMIN_PASSWORD", ADMIN_PASSWORD)
    client = app.test_client()
    # Log in
    client.post("/admin/login", data={"password": ADMIN_PASSWORD})
    return client


def test_analysis_page_loads(admin_client):
    """GET /admin/analysis returns 200."""
    resp = admin_client.get("/admin/analysis")
    assert resp.status_code == 200
    assert b"New Analysis" in resp.data


def test_analysis_page_requires_auth(client):
    """GET /admin/analysis redirects without auth."""
    resp = client.get("/admin/analysis")
    assert resp.status_code == 302


def test_analysis_run_requires_api_key(admin_client, app, monkeypatch):
    """POST /admin/analysis/run fails without ANTHROPIC_API_KEY."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    resp = admin_client.post(
        "/admin/analysis/run",
        data={"date_from": "2026-01-10", "date_to": "2026-01-12"},
    )
    assert resp.status_code == 302  # redirect back with flash


def test_analysis_run_end_to_end(admin_client, app, monkeypatch):
    """POST /admin/analysis/run creates analysis and redirects to detail."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={"date_from": "2026-01-10", "date_to": "2026-01-12"},
            follow_redirects=False,
        )

    assert resp.status_code == 302
    assert "/admin/analysis/" in resp.headers["Location"]

    # Clean up
    os.environ.pop("ANTHROPIC_API_KEY", None)


def test_analysis_detail_page(admin_client, app):
    """GET /admin/analysis/<id> shows the analysis detail."""
    _insert_test_data(app)
    os.environ["ANTHROPIC_API_KEY"] = "test-key"

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={"date_from": "2026-01-10", "date_to": "2026-01-12"},
            follow_redirects=True,
        )

    assert resp.status_code == 200
    assert b"Anxiety has been stable" in resp.data
    assert b"HRV inversely correlates" in resp.data

    os.environ.pop("ANTHROPIC_API_KEY", None)


def test_analysis_detail_not_found(admin_client):
    """GET /admin/analysis/999 redirects with flash."""
    resp = admin_client.get("/admin/analysis/999")
    assert resp.status_code == 302
