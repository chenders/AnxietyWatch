"""Tests for conflict analysis prompt builders and result parsers."""

import hashlib
import json
import os
import sys
from unittest.mock import MagicMock

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


def _setup_profiles_and_conflict(app):
    """Insert test profiles and conflict for prompt building."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO patient_profile (name, profile_summary) "
            "VALUES ('Test User', 'Male, 34, GAD since 2018. Takes Clonazepam 1mg.')"
        )
        cur.execute(
            "INSERT INTO psychiatrist_profile (name, location, profile_summary) "
            "VALUES ('Jane Smith MD', 'Portland, OR', 'Board-certified anxiety specialist.')"
        )
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective, patient_assumptions, "
            "patient_desired_resolution, patient_wants_from_other, "
            "psychiatrist_perspective, psychiatrist_assumptions, "
            "psychiatrist_desired_resolution, psychiatrist_wants_from_other, "
            "additional_context) VALUES ("
            "'Disagreement about taper speed', "
            "'Taper is too fast', 'Rapid tapers cause rebound', "
            "'Slower taper', 'More conservative approach', "
            "'Current pace follows guidelines', 'Patient can handle it', "
            "'Continue current plan', 'Trust the process', "
            "'3 years on medication') RETURNING id"
        )
        conflict_id = cur.fetchone()[0]
        db.commit()
    return conflict_id


def test_build_job_prompt_patient_validity(app):
    """build_job_prompt for patient_validity includes correct system and context."""
    conflict_id = _setup_profiles_and_conflict(app)
    with app.app_context():
        db = app.get_db()
        from conflict_analysis import build_job_prompt

        job = {
            "job_type": "patient_validity",
            "conflict_id": conflict_id,
            "analysis_id": 1,
        }
        dep_results = {
            "health_analysis": {"summary": "Anxiety elevated this week, HRV down."},
        }
        system, user_msg, tools = build_job_prompt(db, job, dep_results)

    assert "medical research analyst" in system.lower()
    assert "patient's position" in system.lower()
    assert "Test User" in user_msg or "GAD since 2018" in user_msg
    assert "Taper is too fast" in user_msg
    assert "HRV down" in user_msg
    assert tools is not None  # web search tool


def test_build_job_prompt_psychiatrist_criticism(app):
    """build_job_prompt for psychiatrist_criticism targets psychiatrist's position."""
    conflict_id = _setup_profiles_and_conflict(app)
    with app.app_context():
        db = app.get_db()
        from conflict_analysis import build_job_prompt

        job = {
            "job_type": "psychiatrist_criticism",
            "conflict_id": conflict_id,
            "analysis_id": 1,
        }
        dep_results = {
            "health_analysis": {"summary": "Summary text."},
        }
        system, user_msg, tools = build_job_prompt(db, job, dep_results)

    assert "challenges or contradicts" in system.lower()
    assert "psychiatrist" in system.lower()


def test_build_job_prompt_synthesis(app):
    """build_job_prompt for conflict_synthesis includes all 4 research results."""
    conflict_id = _setup_profiles_and_conflict(app)
    with app.app_context():
        db = app.get_db()
        from conflict_analysis import build_job_prompt

        job = {
            "job_type": "conflict_synthesis",
            "conflict_id": conflict_id,
            "analysis_id": 1,
        }
        dep_results = {
            "patient_validity": {"findings": [{"claim": "A", "assessment": "B"}]},
            "psychiatrist_validity": {"findings": [{"claim": "C", "assessment": "D"}]},
            "patient_criticism": {"findings": [{"claim": "E", "assessment": "F"}]},
            "psychiatrist_criticism": {"findings": [{"claim": "G", "assessment": "H"}]},
        }
        system, user_msg, tools = build_job_prompt(db, job, dep_results)

    assert "clinical conflict analyst" in system.lower()
    assert "patient_validity" in user_msg or "Evidence Supporting Patient" in user_msg
    assert tools is None  # synthesis doesn't use web search


def test_parse_job_result_research(app):
    """parse_job_result extracts findings from a research job response."""
    from conflict_analysis import parse_job_result

    findings_json = json.dumps({
        "findings": [
            {
                "claim": "Benzodiazepine tapers should be gradual",
                "assessment": "APA guidelines recommend 10% reduction every 1-2 weeks",
                "sources": [{"title": "APA Guidelines 2023", "type": "clinical_guideline"}],
                "confidence": 0.85,
                "confidence_explanation": "Well-established guideline",
            }
        ]
    })
    mock_msg = MagicMock()
    mock_msg.content = [MagicMock(text=findings_json, type="text")]

    result = parse_job_result("patient_validity", mock_msg)
    assert "findings" in result
    assert len(result["findings"]) == 1
    assert result["findings"][0]["confidence"] == 0.85


def test_parse_job_result_synthesis(app):
    """parse_job_result extracts synthesis structure from response."""
    from conflict_analysis import parse_job_result

    synthesis_json = json.dumps({
        "summary": "The evidence suggests a balanced approach.",
        "patient_position_assessment": {
            "supported_by_evidence": [],
            "challenged_by_evidence": [],
            "overall_strength": "moderate",
        },
        "psychiatrist_position_assessment": {
            "supported_by_evidence": [],
            "challenged_by_evidence": [],
            "overall_strength": "moderate",
        },
        "areas_of_agreement": ["Both agree medication is helpful"],
        "key_disagreements": [],
        "suggested_paths_forward": [],
        "confidence": 0.7,
        "confidence_explanation": "Limited direct evidence for this specific case",
    })
    mock_msg = MagicMock()
    mock_msg.content = [MagicMock(text=synthesis_json, type="text")]

    result = parse_job_result("conflict_synthesis", mock_msg)
    assert "summary" in result
    assert result["patient_position_assessment"]["overall_strength"] == "moderate"
