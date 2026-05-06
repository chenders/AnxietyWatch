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


def test_build_prompt_default_includes_medication_goal(app):
    """build_prompt without caveat includes medication effectiveness goal and always-on DQ notes."""
    with app.app_context():
        from analysis import build_prompt
        system, _user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )

    assert "medication effectiveness" in system.lower()
    # Data Quality Notes is always present (CPAP assumption + timezone at minimum)
    assert "Data Quality Notes" in system
    assert "CPAP" in system
    assert "US/Pacific" in system


def test_build_prompt_dose_caveat_removes_medication_goal(app):
    """build_prompt with dose_tracking_incomplete removes medication effectiveness goal and adds caveat."""
    with app.app_context():
        from analysis import build_prompt
        system, user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [],
             "medication_doses": [{"timestamp": "2026-01-10T08:00:00", "medication_name": "TestMed", "dose_mg": 1.0}],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
            dose_tracking_incomplete=True,
        )

    # Medication effectiveness goal removed
    assert "medication effectiveness" not in system.lower()
    # Caveat injected
    assert "Data Quality Notes" in system
    assert "dose log is incomplete" in system
    # Medication data still sent in user message
    assert "medication_doses" in user_msg
    assert "TestMed" in user_msg


def test_build_prompt_includes_reliability_tier_definitions(app):
    """build_prompt system message defines all four reliability tiers."""
    with app.app_context():
        from analysis import build_prompt
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )

    # Tier definitions per the spec
    assert "reliability tier" in system.lower()
    assert "`high`" in system
    assert "`medium`" in system
    assert "`low`" in system
    assert "`insufficient`" in system
    assert "do not cite the metric" in system.lower()


def test_build_prompt_includes_absence_vs_zero_rule_verbatim(app):
    """build_prompt system prompt contains the verbatim absence-vs-zero rule from the spec."""
    with app.app_context():
        from analysis import build_prompt
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )

    # Verbatim text from the spec
    assert "Absence of data is not the same as a zero or low value." in system
    # SpO2 apnea example must be present
    assert "SpO₂ silent overnight does **not** indicate apnea or hypoxia" in system
    # HR off-wrist example
    assert "HR silent for hours does **not** indicate cardiac arrest" in system
    # Glucose silent example
    assert "Glucose silent for an afternoon does **not** indicate hypoglycemia" in system
    # Sleep silent example
    assert "Sleep silent for a date range does **not** mean the patient stopped sleeping" in system
    # Rendering instruction
    assert "no SpO₂ data captured this night" in system


def test_build_prompt_data_quality_section_header(app):
    """The reliability + absence rule lives under a clearly labeled section header."""
    with app.app_context():
        from analysis import build_prompt
        system, _ = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 1), date(2026, 1, 7),
        )

    # We accept either "Data Quality Notes" (existing) or a more specific
    # "Data quality notes" / "Data Quality and Reliability" header — the spec
    # asks for a clearly-labeled section the model can latch onto.
    lowered = system.lower()
    assert "data quality" in lowered


def test_build_prompt_per_day_data_quality_block(app):
    """For a snapshot with non-null data_quality, per-day block emits reliability + sources lines."""
    with app.app_context():
        from analysis import build_prompt
        data_quality = {
            "glucose": {"reliability": "high", "sources": {"com.dexcom.stelo": 287}},
            "spo2": {
                "reliability": "high",
                "sources": {"com.emay.SleepO2": 462, "com.apple.health": 3},
            },
            "hr": {"reliability": "high", "sources": {"com.apple.health": 1438}},
        }
        snapshot = {
            "date": "2026-01-10",
            "hrv_avg": 45.0,
            "resting_hr": 62,
            "data_quality": data_quality,
        }
        _system, user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [snapshot], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 10), date(2026, 1, 10),
        )

    # New per-day data quality section title
    assert "Data quality per day" in user_msg or "data quality per day" in user_msg.lower()
    # The day's date is referenced
    assert "2026-01-10" in user_msg
    # Each metric family present in data_quality is rendered
    assert "glucose:" in user_msg
    assert "spo2:" in user_msg
    assert "hr:" in user_msg
    # Reliability and sources lines per family
    assert "reliability: high" in user_msg
    assert "sources:" in user_msg
    # Display-name mapping converts bundle IDs (Stelo, EMAY SleepO2, Apple Watch)
    assert "Stelo" in user_msg
    assert "EMAY SleepO2" in user_msg
    assert "Apple Watch" in user_msg
    # Counts preserved
    assert "287" in user_msg
    assert "462" in user_msg


def test_build_prompt_per_day_data_quality_handles_null(app):
    """A snapshot with NULL data_quality renders gracefully without crashing."""
    with app.app_context():
        from analysis import build_prompt
        snapshot = {
            "date": "2026-01-10",
            "hrv_avg": 45.0,
            "resting_hr": 62,
            "data_quality": None,
        }
        _system, user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [snapshot], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 10), date(2026, 1, 10),
        )

    # Either omit the day's block or render a "not yet computed" placeholder —
    # the only hard requirement is no crash and a reasonable rendering.
    assert "2026-01-10" in user_msg
    # The user message should still reference some form of data quality awareness
    assert "data quality" in user_msg.lower() or "data_quality" in user_msg.lower()


def test_build_prompt_per_day_data_quality_handles_non_numeric_sources(app):
    """`sources` blob with non-numeric counts must not crash prompt building.

    Older or hand-edited `data_quality.sources` rows can contain strings or
    nulls instead of ints. The sort key in `_format_per_day_data_quality`
    must coerce defensively rather than blowing up the entire analysis.
    """
    with app.app_context():
        from analysis import build_prompt
        data_quality = {
            "glucose": {
                "reliability": "high",
                # Mixed bag: int, numeric string, None, and a non-numeric string.
                "sources": {
                    "com.dexcom.stelo": 287,
                    "com.dexcom.G7": "12",
                    "com.apple.health": None,
                    "com.unknown.weird": "not-a-number",
                },
            },
        }
        snapshot = {
            "date": "2026-01-10",
            "hrv_avg": 45.0,
            "resting_hr": 62,
            "data_quality": data_quality,
        }
        # Smoke test: build_prompt must not raise.
        _system, user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [snapshot], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 10), date(2026, 1, 10),
        )

    # Prompt rendered something for this day — the misbehaving entries didn't
    # short-circuit the whole block.
    assert "2026-01-10" in user_msg
    assert "glucose:" in user_msg
    assert "Stelo" in user_msg
    # Within the rendered "sources: { ... }" block (NOT the raw JSON snapshot
    # dump earlier in the message), the highest numeric count must rank first
    # and non-numeric entries must sort last (coerced to 0). Locate the
    # rendered block so we don't accidentally measure ordering in the JSON
    # snapshot section.
    sources_block_start = user_msg.index("sources: {", user_msg.index("glucose:"))
    sources_block_end = user_msg.index("}", sources_block_start)
    sources_block = user_msg[sources_block_start:sources_block_end]
    assert sources_block.index("Stelo") < sources_block.index("com.unknown.weird")
    # Apple Watch (None count) and unknown.weird (non-numeric) both coerce to
    # 0, so they're listed after Stelo and Dexcom G7.
    assert sources_block.index("Dexcom G7") < sources_block.index("com.unknown.weird")


def test_build_prompt_per_day_data_quality_ties_break_alphabetically(app):
    """Equal source counts must sort alphabetically by bundle ID for determinism.

    Without a secondary sort key, two sources with identical counts come back
    in dict-insertion order, which differs between JSON producers (psycopg2
    dict, json.loads, hand-edited fixtures) and makes the rendered prompt
    non-deterministic. Pin the tiebreaker so prompt output is stable.
    """
    with app.app_context():
        from analysis import build_prompt
        # Two sources with identical counts. Insertion order intentionally
        # places "com.zeta.late" first to prove it's the sort, not insertion
        # order, that decides the rendering.
        data_quality = {
            "glucose": {
                "reliability": "high",
                "sources": {
                    "com.zeta.late": 100,
                    "com.alpha.early": 100,
                },
            },
        }
        snapshot = {
            "date": "2026-01-10",
            "hrv_avg": 45.0,
            "resting_hr": 62,
            "data_quality": data_quality,
        }
        _system, user_msg = build_prompt(
            {"anxiety_entries": [], "health_snapshots": [snapshot], "medication_doses": [],
             "cpap_sessions": [], "barometric_readings": [], "correlations": []},
            date(2026, 1, 10), date(2026, 1, 10),
        )

    # Locate the rendered "sources: { ... }" block (NOT the raw JSON snapshot
    # dump earlier in the message).
    sources_block_start = user_msg.index("sources: {", user_msg.index("glucose:"))
    sources_block_end = user_msg.index("}", sources_block_start)
    sources_block = user_msg[sources_block_start:sources_block_end]

    # Both bundle IDs survive the display-name lookup unchanged because they
    # aren't in DEVICE_DISPLAY_NAMES; the alphabetical bundle-ID order should
    # therefore match the rendered substring order.
    assert sources_block.index("com.alpha.early") < sources_block.index("com.zeta.late"), (
        "Tied counts must break alphabetically by bundle ID for deterministic prompt output"
    )


def test_format_per_day_data_quality_renders_canonical_display_name(app):
    """Dict-shape `sources` with a known bundle ID renders the canonical
    display name (`Stelo`) rather than the raw reverse-DNS string
    (`com.dexcom.stelo`).

    This pins the wire format: `sources` is a dict keyed by bundle ID, never
    a list of display strings. Round-9 review explicitly rejected list-shape
    fallback handling — supporting two parallel rendering paths is a
    maintenance trap, and the iOS client never emits list-shape sources.
    """
    with app.app_context():
        from analysis import _format_per_day_data_quality
        snapshot = {
            "date": "2026-01-10",
            "data_quality": {
                "glucose": {
                    "reliability": "high",
                    "sources": {"com.dexcom.stelo": 287},
                },
            },
        }
        rendered = _format_per_day_data_quality([snapshot])

    # Canonical display name appears with its count.
    assert "Stelo: 287" in rendered, (
        "Dict-shape sources with a known bundle ID must render the display name"
    )
    # The raw bundle ID does NOT leak into the rendered sources block.
    sources_block_start = rendered.index("sources: {", rendered.index("glucose:"))
    sources_block_end = rendered.index("}", sources_block_start)
    sources_block = rendered[sources_block_start:sources_block_end]
    assert "com.dexcom.stelo" not in sources_block, (
        "Known bundle IDs must be replaced with the canonical display name"
    )
    # Sanity check: the rendered block is NOT the "not captured" placeholder
    # (which is what list-shape sources would silently produce).
    assert "not captured" not in rendered


def test_format_per_day_data_quality_renders_counts_as_ints(app):
    """Per-source counts must be rendered as ints, not the raw JSON value.

    `data_quality.sources` is a JSONB blob written by the iOS client; older or
    hand-edited rows can carry `None` or numeric strings (`"12"`). The sort
    key already coerces with `_safe_int`, but the rendered string previously
    interpolated the raw value — surfacing strings like `Apple Watch: None`
    in the prompt sent to Claude. Coerce on render too so the prompt always
    shows clean integers.
    """
    with app.app_context():
        from analysis import _format_per_day_data_quality
        snapshot = {
            "date": "2026-01-10",
            "data_quality": {
                "glucose": {
                    "reliability": "high",
                    "sources": {
                        # Numeric string — should render as 12, not "12".
                        "com.dexcom.G7": "12",
                        # None — should render as 0, not "None".
                        "com.apple.health": None,
                        # Non-numeric string — should render as 0, not the raw text.
                        "com.unknown.weird": "not-a-number",
                    },
                },
            },
        }
        rendered = _format_per_day_data_quality([snapshot])

    # Locate the rendered "sources: { ... }" block — we must not accidentally
    # match against any raw JSON snapshot dump elsewhere in the prompt.
    sources_block_start = rendered.index("sources: {", rendered.index("glucose:"))
    sources_block_end = rendered.index("}", sources_block_start)
    sources_block = rendered[sources_block_start:sources_block_end]

    # Strings and Nones must not leak through into the prompt.
    assert "None" not in sources_block, (
        "None counts must coerce to 0, not render as the literal 'None'"
    )
    assert "not-a-number" not in sources_block, (
        "Non-numeric string counts must coerce to 0, not surface as raw text"
    )
    # The numeric-string '12' must render as the int 12, with no quotes.
    assert "Dexcom G7: 12" in sources_block, (
        "Numeric-string counts must render as bare integers"
    )
    # The None and non-numeric entries should both render as 0 — the coerced
    # int — even though the raw blob held something else.
    assert "Apple Watch: 0" in sources_block or "com.apple.health: 0" in sources_block, (
        "None counts must render as 0 in the prompt"
    )
    assert "com.unknown.weird: 0" in sources_block, (
        "Non-numeric string counts must render as 0 in the prompt"
    )


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


def _wait_for_analysis_threads(timeout: float = 10.0) -> None:
    """Join any active background analysis threads (names start with 'analysis-').

    Loops until no 'analysis-' threads are alive or the overall deadline elapses.
    Recomputes the remaining budget for each join() so the total wall-clock wait
    is bounded by `timeout` regardless of how many threads are alive.
    """
    import threading
    import time
    deadline = time.monotonic() + timeout
    while True:
        analysis_threads = [
            t for t in threading.enumerate()
            if t.name.startswith("analysis-") and t.is_alive()
        ]
        if not analysis_threads:
            return
        for t in analysis_threads:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            t.join(timeout=remaining)
        time.sleep(0.01)


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
        _wait_for_analysis_threads()

    assert resp.status_code == 302
    assert "/admin/analysis/" in resp.headers["Location"]


def test_analysis_detail_page(admin_client, app, monkeypatch):
    """GET /admin/analysis/<id> shows the analysis detail."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        post_resp = admin_client.post(
            "/admin/analysis/run",
            data={"date_from": "2026-01-10", "date_to": "2026-01-12"},
            follow_redirects=False,
        )
        _wait_for_analysis_threads()
        resp = admin_client.get(post_resp.headers["Location"])

    assert resp.status_code == 200
    assert b"Anxiety has been stable" in resp.data
    assert b"HRV inversely correlates" in resp.data


def test_sweep_stale_analyses_marks_old_running_as_failed(app):
    """sweep_stale_analyses flips stale pending/running rows to failed."""
    with app.app_context():
        from analysis import sweep_stale_analyses
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO analyses (date_from, date_to, status, model, created_at) "
            "VALUES (%s, %s, 'running', 'test', NOW() - INTERVAL '1 hour') RETURNING id",
            (date(2026, 1, 10), date(2026, 1, 12)),
        )
        stale_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO analyses (date_from, date_to, status, model, created_at) "
            "VALUES (%s, %s, 'running', 'test', NOW()) RETURNING id",
            (date(2026, 1, 10), date(2026, 1, 12)),
        )
        fresh_id = cur.fetchone()[0]
        db.commit()

        updated = sweep_stale_analyses(db, force=True)
        assert updated == 1

        cur.execute("SELECT status FROM analyses WHERE id = %s", (stale_id,))
        assert cur.fetchone()[0] == "failed"
        cur.execute("SELECT status FROM analyses WHERE id = %s", (fresh_id,))
        assert cur.fetchone()[0] == "running"


def test_start_analysis_runs_in_background(app, monkeypatch):
    """start_analysis inserts a pending row immediately and completes in a worker thread."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with app.app_context():
        from analysis import start_analysis, get_analysis
        db = app.get_db()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            analysis_id = start_analysis(
                db, date(2026, 1, 10), date(2026, 1, 12), database_url=DATABASE_URL
            )
            _wait_for_analysis_threads()

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    assert result["status"] == "completed"
    assert result["summary"] == "Anxiety has been stable over this period."


def test_analysis_detail_not_found(admin_client):
    """GET /admin/analysis/999 redirects with flash."""
    resp = admin_client.get("/admin/analysis/999")
    assert resp.status_code == 302


def test_run_analysis_stores_dose_tracking_flag(app):
    """run_analysis stores dose_tracking_incomplete in the DB row."""
    _insert_test_data(app)
    with app.app_context():
        from analysis import run_analysis, get_analysis
        db = app.get_db()

        mock_client = MagicMock()
        mock_client.messages.create.return_value = _mock_anthropic_response()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            analysis_id = run_analysis(
                db, date(2026, 1, 10), date(2026, 1, 12),
                dose_tracking_incomplete=True,
            )

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    assert result["dose_tracking_incomplete"] is True


def test_run_analysis_default_dose_tracking_false(app):
    """run_analysis defaults dose_tracking_incomplete to False."""
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

    assert result["dose_tracking_incomplete"] is False


def test_analysis_run_with_checkbox(admin_client, app, monkeypatch):
    """POST /admin/analysis/run with checkbox sends dose_tracking_incomplete."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={
                "date_from": "2026-01-10",
                "date_to": "2026-01-12",
                "dose_tracking_incomplete": "on",
            },
            follow_redirects=False,
        )
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        from analysis import list_analyses
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        analyses = list_analyses(cur)

    assert len(analyses) == 1
    assert analyses[0]["dose_tracking_incomplete"] is True


def test_analysis_run_without_checkbox(admin_client, app, monkeypatch):
    """POST /admin/analysis/run without checkbox defaults to False."""
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
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        from analysis import list_analyses
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        analyses = list_analyses(cur)

    assert len(analyses) == 1
    assert analyses[0]["dose_tracking_incomplete"] is False


def test_build_prompt_plain_english_by_default():
    """build_prompt includes Writing Style section when detailed_output is False."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(data, date(2026, 1, 1), date(2026, 1, 7))
    assert "## Writing Style" in system
    assert "plain language" in system.lower()


def test_build_prompt_detailed_output_omits_writing_style():
    """build_prompt omits Writing Style section when detailed_output is True."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(data, date(2026, 1, 1), date(2026, 1, 7), detailed_output=True)
    assert "## Writing Style" not in system


def test_build_prompt_detailed_output_includes_inline_stats():
    """build_prompt summary field asks for inline numbers when detailed_output is True."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(data, date(2026, 1, 1), date(2026, 1, 7), detailed_output=True)
    assert "thorough and specific with numbers" in system.lower()


def test_analysis_run_detailed_output_e2e(admin_client, app, monkeypatch):
    """POST /admin/analysis/run with detailed_output checkbox stores detailed prompt."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={
                "date_from": "2026-01-10",
                "date_to": "2026-01-12",
                "detailed_output": "on",
            },
            follow_redirects=False,
        )
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        from analysis import get_analysis, list_analyses
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        analyses = list_analyses(cur)
        assert len(analyses) == 1
        result = get_analysis(cur, analyses[0]["id"])

    system_prompt = result["request_payload"]["system"]
    assert "## Writing Style" not in system_prompt
    assert "thorough and specific" in system_prompt.lower()


def test_analysis_run_default_plain_english_e2e(admin_client, app, monkeypatch):
    """POST /admin/analysis/run without detailed_output stores plain English prompt."""
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
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        from analysis import get_analysis, list_analyses
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        analyses = list_analyses(cur)
        assert len(analyses) == 1
        result = get_analysis(cur, analyses[0]["id"])

    system_prompt = result["request_payload"]["system"]
    assert "## Writing Style" in system_prompt
    assert "plain language" in system_prompt.lower()


# ---------------------------------------------------------------------------
# Tests for flag_outliers
# ---------------------------------------------------------------------------


def test_flag_outliers_clean_data():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "sleep_duration_min": 480, "resting_hr": 65,
         "hrv_avg": 45, "spo2_avg": 97, "steps": 8000},
    ]}
    assert flag_outliers(data) == []


def test_flag_outliers_sleep_over_limit():
    from analysis import flag_outliers
    data = {"health_snapshots": [{"date": "2026-04-04", "sleep_duration_min": 1277}]}
    warnings = flag_outliers(data)
    assert len(warnings) == 1
    assert "sleep_duration_min" in warnings[0]
    assert "1277" in warnings[0]


def test_flag_outliers_hr_out_of_range():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "resting_hr": 185},
        {"date": "2026-01-11", "resting_hr": 15},
    ]}
    warnings = flag_outliers(data)
    assert len(warnings) == 2


def test_flag_outliers_sleep_stage_inconsistency():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "sleep_duration_min": 420,
         "sleep_deep_min": 200, "sleep_rem_min": 150,
         "sleep_core_min": 200, "sleep_awake_min": 30},
    ]}
    warnings = flag_outliers(data)
    assert len(warnings) == 1
    assert "exceeds" in warnings[0].lower()


def test_flag_outliers_skips_null_fields():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "sleep_duration_min": None, "resting_hr": None},
    ]}
    assert flag_outliers(data) == []


def test_flag_outliers_multiple_days():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "sleep_duration_min": 1400, "bp_systolic": 300},
        {"date": "2026-01-11", "blood_glucose_avg": 600},
    ]}
    assert len(flag_outliers(data)) == 3


def test_flag_outliers_no_snapshots():
    from analysis import flag_outliers
    assert flag_outliers({"anxiety_entries": []}) == []


def test_flag_outliers_all_limit_types():
    from analysis import flag_outliers
    data = {"health_snapshots": [
        {"date": "2026-01-10", "hrv_avg": 0},
        {"date": "2026-01-11", "spo2_avg": 50},
        {"date": "2026-01-12", "respiratory_rate": 2},
        {"date": "2026-01-13", "bp_diastolic": 200},
        {"date": "2026-01-14", "blood_glucose_avg": 5},
        {"date": "2026-01-15", "steps": 200000},
        {"date": "2026-01-16", "active_calories": 10000},
        {"date": "2026-01-17", "exercise_minutes": 600},
        {"date": "2026-01-18", "skin_temp_deviation": -10.0},
    ]}
    assert len(flag_outliers(data)) == 9


# ---------------------------------------------------------------------------
# Tests for compute_effective_dates
# ---------------------------------------------------------------------------


def test_compute_effective_dates_trims_to_data():
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [{"timestamp": "2026-01-15T12:00:00"}, {"timestamp": "2026-03-20T08:00:00"}],
        "health_snapshots": [{"date": "2026-01-20"}, {"date": "2026-03-15"}],
        "medication_doses": [], "cpap_sessions": [], "barometric_readings": [],
    }
    eff_from, eff_to = compute_effective_dates(data, date(2025, 12, 1), date(2026, 4, 30))
    assert eff_from == date(2026, 1, 15)
    assert eff_to == date(2026, 3, 20)


def test_compute_effective_dates_no_data():
    from analysis import compute_effective_dates
    data = {"anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
            "cpap_sessions": [], "barometric_readings": []}
    eff_from, eff_to = compute_effective_dates(data, date(2026, 1, 1), date(2026, 1, 31))
    assert eff_from == date(2026, 1, 1)
    assert eff_to == date(2026, 1, 31)


def test_compute_effective_dates_single_day():
    from analysis import compute_effective_dates
    data = {"anxiety_entries": [], "health_snapshots": [{"date": "2026-02-14"}],
            "medication_doses": [], "cpap_sessions": [], "barometric_readings": []}
    eff_from, eff_to = compute_effective_dates(data, date(2026, 1, 1), date(2026, 3, 31))
    assert eff_from == date(2026, 2, 14)
    assert eff_to == date(2026, 2, 14)


def test_compute_effective_dates_mixed_sources():
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [], "health_snapshots": [],
        "medication_doses": [{"timestamp": "2026-02-01T10:00:00"}],
        "cpap_sessions": [{"date": "2026-03-01"}],
        "barometric_readings": [{"timestamp": "2026-02-15T14:30:00"}],
    }
    eff_from, eff_to = compute_effective_dates(data, date(2026, 1, 1), date(2026, 4, 1))
    assert eff_from == date(2026, 2, 1)
    assert eff_to == date(2026, 3, 1)


# ---------------------------------------------------------------------------
# Prompt integration tests — build_prompt with new data quality params
# ---------------------------------------------------------------------------


def test_build_prompt_outlier_warnings_in_dq_notes():
    """build_prompt includes outlier warnings in Data Quality Notes."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(
        data, date(2026, 1, 1), date(2026, 1, 7),
        outlier_warnings=["2026-01-03: resting_hr=185 outside [25, 170]"],
    )
    assert "physiologically implausible" in system.lower()
    assert "resting_hr=185" in system


def test_build_prompt_cpap_note_always_present():
    """build_prompt always includes the CPAP assumption note."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(data, date(2026, 1, 1), date(2026, 1, 7))
    assert "CPAP" in system
    assert "not been imported" in system


def test_build_prompt_custom_timezone():
    """build_prompt includes the configured timezone."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(
        data, date(2026, 1, 1), date(2026, 1, 7), timezone="US/Eastern",
    )
    assert "US/Eastern" in system


def test_build_prompt_therapy_schedule_formatting():
    """build_prompt formats therapy sessions into natural-language schedule."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    sessions = [
        {"day_of_week": 0, "day_of_month": None, "time_of_day": "14:30:00",
         "session_type": "virtual", "commute_minutes": 0, "notes": None,
         "frequency": "weekly"},
        {"day_of_week": 3, "day_of_month": None, "time_of_day": "13:00:00",
         "session_type": "in-person", "commute_minutes": 30,
         "notes": "often 5-10 minutes late", "frequency": "weekly"},
    ]
    system, _ = build_prompt(
        data, date(2026, 1, 1), date(2026, 1, 7), therapy_sessions=sessions,
    )
    assert "Therapy schedule" in system
    assert "Mondays" in system
    assert "2:30 PM" in system
    assert "virtual/Zoom" in system
    assert "Thursdays" in system
    assert "1:00 PM" in system
    assert "30 min commute" in system
    assert "often 5-10 minutes late" in system


def test_build_prompt_dose_caveat_plus_outliers_coexist():
    """build_prompt includes both dose caveat and outlier warnings together."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    system, _ = build_prompt(
        data, date(2026, 1, 1), date(2026, 1, 7),
        dose_tracking_incomplete=True,
        outlier_warnings=["2026-01-05: steps=200000 outside [0, 100000]"],
    )
    assert "dose log is incomplete" in system
    assert "steps=200000" in system
    assert "CPAP" in system


def test_build_prompt_effective_dates_in_user_message():
    """build_prompt uses effective (trimmed) dates in user message."""
    from analysis import build_prompt
    data = {
        "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
        "cpap_sessions": [], "barometric_readings": [], "correlations": [],
    }
    _, user_msg = build_prompt(data, date(2026, 2, 5), date(2026, 2, 20))
    assert "2026-02-05" in user_msg
    assert "2026-02-20" in user_msg


# ---------------------------------------------------------------------------
# Wiring integration tests — _create_pending_analysis reads from DB
# ---------------------------------------------------------------------------


def test_wiring_flags_outliers(app):
    """_create_pending_analysis includes outlier warnings in the prompt."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        # Insert a snapshot with an impossible resting HR
        cur.execute(
            "INSERT INTO health_snapshots (date, resting_hr) VALUES (%s, %s)",
            (date(2026, 1, 10), 250),
        )
        db.commit()

        from analysis import _create_pending_analysis
        _id, system_prompt, _user_msg = _create_pending_analysis(
            db, date(2026, 1, 10), date(2026, 1, 10),
        )

    assert "resting_hr" in system_prompt
    assert "250" in system_prompt
    assert "physiologically implausible" in system_prompt.lower()


def test_wiring_trims_effective_dates(app):
    """_create_pending_analysis trims date range to actual data span."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        # Insert data only on Jan 15
        cur.execute(
            "INSERT INTO health_snapshots (date, resting_hr) VALUES (%s, %s)",
            (date(2026, 1, 15), 65),
        )
        db.commit()

        from analysis import _create_pending_analysis
        _id, _system, user_msg = _create_pending_analysis(
            db, date(2026, 1, 1), date(2026, 1, 31),
        )

    # User message should reference the effective dates, not the full range
    assert "2026-01-15" in user_msg
    assert "2026-01-01" not in user_msg
    assert "2026-01-31" not in user_msg


def test_wiring_reads_timezone(app):
    """_create_pending_analysis reads timezone from settings table."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO settings (key, value) VALUES ('timezone', 'America/Chicago') "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value"
        )
        db.commit()

        from analysis import _create_pending_analysis
        _id, system_prompt, _user_msg = _create_pending_analysis(
            db, date(2026, 1, 1), date(2026, 1, 7),
        )

    assert "America/Chicago" in system_prompt


def test_wiring_reads_therapy_sessions(app):
    """_create_pending_analysis reads active therapy sessions from DB."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO therapy_sessions "
            "(frequency, day_of_week, time_of_day, session_type, commute_minutes, is_active) "
            "VALUES ('weekly', 4, '14:00', 'in-person', 30, TRUE)"
        )
        # Inactive session should be excluded
        cur.execute(
            "INSERT INTO therapy_sessions "
            "(frequency, day_of_week, time_of_day, session_type, commute_minutes, is_active) "
            "VALUES ('weekly', 2, '10:00', 'virtual', 0, FALSE)"
        )
        db.commit()

        from analysis import _create_pending_analysis
        _id, system_prompt, _user_msg = _create_pending_analysis(
            db, date(2026, 1, 1), date(2026, 1, 7),
        )

    assert "Fridays" in system_prompt
    assert "2:00 PM" in system_prompt
    assert "30 min commute" in system_prompt
    # Inactive session's day (Wednesday) should NOT appear
    assert "Wednesdays" not in system_prompt


def test_wiring_default_timezone_when_unset(app):
    """_create_pending_analysis defaults to US/Pacific when no timezone setting exists."""
    with app.app_context():
        db = app.get_db()

        from analysis import _create_pending_analysis
        _id, system_prompt, _user_msg = _create_pending_analysis(
            db, date(2026, 1, 1), date(2026, 1, 7),
        )

    assert "US/Pacific" in system_prompt


def test_analysis_run_custom_model_persisted(admin_client, app, monkeypatch):
    """POST /admin/analysis/run with model selection persists it on analyses and jobs."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={
                "date_from": "2026-01-10",
                "date_to": "2026-01-12",
                "model": "claude-opus-4-5-20250414",
            },
            follow_redirects=False,
        )
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT model FROM analyses ORDER BY id DESC LIMIT 1")
        assert cur.fetchone()["model"] == "claude-opus-4-5-20250414"
        cur.execute("SELECT model FROM analysis_jobs ORDER BY id")
        for job in cur.fetchall():
            assert job["model"] == "claude-opus-4-5-20250414"


def test_analysis_run_conflict_toggle_unchecked(admin_client, app, monkeypatch):
    """Unchecking include_conflict suppresses conflict jobs even with active conflict."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    # Create active conflict
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective, psychiatrist_perspective) "
            "VALUES ('Test conflict', 'Patient view', 'Psychiatrist view')"
        )
        db.commit()

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={
                "date_from": "2026-01-10",
                "date_to": "2026-01-12",
                "conflict_toggle_shown": "1",
                # include_conflict deliberately omitted → unchecked
            },
            follow_redirects=False,
        )
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT job_type FROM analysis_jobs ORDER BY id")
        job_types = [r["job_type"] for r in cur.fetchall()]

    assert job_types == ["health_analysis"]


def test_analysis_run_conflict_toggle_checked(admin_client, app, monkeypatch):
    """Checking include_conflict creates conflict jobs when active conflict exists."""
    _insert_test_data(app)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective, psychiatrist_perspective) "
            "VALUES ('Test conflict', 'Patient view', 'Psychiatrist view')"
        )
        db.commit()

    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_anthropic_response()

    with patch("analysis.anthropic.Anthropic", return_value=mock_client):
        resp = admin_client.post(
            "/admin/analysis/run",
            data={
                "date_from": "2026-01-10",
                "date_to": "2026-01-12",
                "conflict_toggle_shown": "1",
                "include_conflict": "on",
            },
            follow_redirects=False,
        )
        _wait_for_analysis_threads()

    assert resp.status_code == 302

    with app.app_context():
        db = app.get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT job_type FROM analysis_jobs ORDER BY id")
        job_types = [r["job_type"] for r in cur.fetchall()]

    assert len(job_types) == 6
    assert "conflict_synthesis" in job_types
