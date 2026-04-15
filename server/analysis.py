"""AI Analysis engine — gathers data, builds prompts, calls Claude, parses results."""

import json
import logging
import os
import threading
from datetime import date, datetime, timedelta, timezone

import anthropic
import psycopg2
import psycopg2.extras

MODEL = "claude-opus-4-6"


def gather_analysis_data(cur, date_from: date, date_to: date) -> dict:
    """Query all data sources for the given date range.

    Returns a dict with keys for each data source, values are lists of dicts.
    """
    data = {}
    ts_start = datetime.combine(date_from, datetime.min.time(), tzinfo=timezone.utc)
    ts_end = datetime.combine(date_to + timedelta(days=1), datetime.min.time(), tzinfo=timezone.utc)

    # Anxiety entries (half-open timestamp range for index usage)
    cur.execute(
        "SELECT timestamp, severity, notes, tags FROM anxiety_entries "
        "WHERE timestamp >= %s AND timestamp < %s "
        "ORDER BY timestamp",
        (ts_start, ts_end),
    )
    data["anxiety_entries"] = [_serialize(r) for r in cur.fetchall()]

    # Health snapshots
    cur.execute(
        "SELECT * FROM health_snapshots WHERE date >= %s AND date <= %s ORDER BY date",
        (date_from, date_to),
    )
    data["health_snapshots"] = [_serialize(r) for r in cur.fetchall()]

    # Medication doses with definition info
    cur.execute(
        "SELECT d.timestamp, d.medication_name, d.dose_mg, d.notes, "
        "m.category, m.default_dose_mg "
        "FROM medication_doses d "
        "LEFT JOIN medication_definitions m ON m.name = d.medication_name "
        "WHERE d.timestamp >= %s AND d.timestamp < %s "
        "ORDER BY d.timestamp",
        (ts_start, ts_end),
    )
    data["medication_doses"] = [_serialize(r) for r in cur.fetchall()]

    # CPAP sessions
    cur.execute(
        "SELECT * FROM cpap_sessions WHERE date >= %s AND date <= %s ORDER BY date",
        (date_from, date_to),
    )
    data["cpap_sessions"] = [_serialize(r) for r in cur.fetchall()]

    # Barometric readings (can be high volume — downsample with a uniform stride if > 500)
    cur.execute(
        "SELECT timestamp, pressure_kpa, relative_altitude_m "
        "FROM barometric_readings "
        "WHERE timestamp >= %s AND timestamp < %s "
        "ORDER BY timestamp",
        (ts_start, ts_end),
    )
    baro_rows = [_serialize(r) for r in cur.fetchall()]
    if len(baro_rows) > 500:
        step = -(-len(baro_rows) // 500)
        baro_rows = baro_rows[::step]
    data["barometric_readings"] = baro_rows

    # Current correlation engine results (context for Claude)
    cur.execute(
        "SELECT signal_name, correlation, p_value, sample_count "
        "FROM correlations ORDER BY ABS(correlation) DESC"
    )
    data["correlations"] = [_serialize(r) for r in cur.fetchall()]

    return data


def build_prompt(data: dict, date_from: date, date_to: date) -> tuple[str, str]:
    """Build system prompt and user message for Claude analysis.

    Returns (system_prompt, user_message).
    """
    system = """You are a clinical data analyst specializing in anxiety disorder pattern recognition. You are analyzing personal health tracking data to find patterns, correlations, and insights that could help understand anxiety triggers and trends.

## Data Sources

The user tracks:
- **Anxiety entries**: Timestamped severity ratings (1-10 scale), free-text notes, and tags
- **Health snapshots**: Daily physiological data from Apple Watch — HRV, resting HR, sleep stages (deep/REM/core/awake), steps, SpO2, skin temp deviation, respiratory rate, blood pressure, blood glucose, CPAP data, barometric pressure
- **Medication doses**: Timestamped doses with medication name, mg amount, and category
- **CPAP sessions**: Daily sleep apnea therapy data — AHI (apnea-hypopnea index), usage minutes, leak rates, pressure stats, event breakdowns (obstructive/central/hypopnea)
- **Barometric readings**: Atmospheric pressure (kPa) and relative altitude
- **Correlations**: Pre-computed Pearson correlations between individual physiological signals and anxiety severity (from the app's correlation engine)

## Analysis Goals

1. **Confirm or challenge suspected patterns** — validate what the data actually shows
2. **Find non-obvious correlations** — even if potentially coincidental, include them with honest confidence scores
3. **Detect temporal patterns** — time-of-day, day-of-week, multi-day sequences, lagged effects (e.g., poor sleep → next-day anxiety)
4. **Evaluate medication effectiveness** — dose-response patterns, timing effects, tolerance development
5. **Identify compound triggers** — multiple factors combining (e.g., poor sleep + low HRV + barometric drop)
6. **Flag anomalies** — unusual data points, sudden shifts, outliers worth investigating
7. **Assess CPAP/sleep apnea connections** — how CPAP compliance and AHI relate to anxiety
8. **Note environmental factors** — barometric pressure changes and their timing relative to anxiety

## Output Format

Respond with valid JSON only. No markdown, no explanation outside the JSON.

```json
{
  "summary": "Multi-paragraph narrative summary of findings for this period. Be thorough and specific with numbers.",
  "trend_direction": "improving | worsening | stable | mixed",
  "insights": [
    {
      "category": "one of: correlation, medication_effectiveness, temporal_pattern, anomaly, sleep_apnea_connection, environmental, compound_trigger, recommendation",
      "severity": "high | medium | low",
      "title": "Short, specific title describing the finding",
      "detail": "Detailed explanation with specific numbers, dates, and reasoning",
      "confidence": 0.85,
      "confidence_explanation": "Why this confidence level — what would raise or lower it, sample size considerations",
      "supporting_data": {
        "relevant_key": "value — include the specific numbers that support this insight"
      }
    }
  ]
}
```

## Confidence Calibration

- **0.9-1.0**: Very strong signal, large sample, consistent pattern, multiple confirming data points
- **0.7-0.89**: Clear pattern with moderate sample size, or strong pattern with small sample
- **0.5-0.69**: Suggestive pattern, small sample, or pattern with notable exceptions
- **0.3-0.49**: Weak signal, very small sample, or speculative but worth noting
- Below 0.3: Don't include — too speculative to be useful

Always explain what would raise or lower the confidence. Distinguish correlation from causation. Note when more data would strengthen a finding.

## Philosophy

Cast a wide net. The user wants:
- Validation of things they might already suspect
- Surprising discoveries they would never think to look for
- Coincidental correlations are OK — label them honestly and let the user investigate
- More information is better than less — use confidence scores to help navigate
- More detail is better than less — include specific numbers, dates, comparisons
- Err on the side of inclusion at lower confidence rather than omission"""

    # Build user message with all the data
    user_parts = [
        f"Analyze this health tracking data from {date_from.isoformat()} to {date_to.isoformat()}.\n"
    ]

    for source_name, rows in data.items():
        user_parts.append(f"## {source_name}")
        user_parts.append(json.dumps(rows, default=str, separators=(",", ":")))
        user_parts.append("")

    user_message = "\n".join(user_parts)

    return system, user_message


def parse_response(raw_response: dict) -> dict:
    """Parse the Claude API response into structured analysis data.

    Args:
        raw_response: The raw response dict from the Anthropic API
            (the message object with content and usage).

    Returns:
        Dict with keys: summary, trend_direction, insights, tokens_in, tokens_out.

    Raises:
        ValueError: If the response text is not valid JSON.
    """
    text = ""
    for block in raw_response.get("content", []):
        if block.get("type") == "text":
            text += block["text"]

    # Strip markdown code fences if present
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text[3:]
    if text.endswith("```"):
        text = text[:-3].rstrip()

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"Failed to parse Claude response as JSON: {e}")

    usage = raw_response.get("usage", {})

    insights = parsed.get("insights", [])
    if not isinstance(insights, list):
        insights = []
    insights = [i for i in insights if isinstance(i, dict)]

    return {
        "summary": parsed.get("summary", ""),
        "trend_direction": parsed.get("trend_direction", "mixed"),
        "insights": insights,
        "tokens_in": usage.get("input_tokens", 0),
        "tokens_out": usage.get("output_tokens", 0),
    }


def _serialize(row):
    """Convert a RealDictRow to a plain dict with JSON-safe values."""
    result = {}
    for k, v in row.items():
        if isinstance(v, datetime):
            result[k] = v.isoformat()
        elif isinstance(v, date):
            result[k] = v.isoformat()
        else:
            result[k] = v
    return result


def start_analysis(db, date_from: date, date_to: date, database_url: str | None = None) -> int:
    """Create a pending analysis row and kick off the Claude call in a background thread.

    Returns the analysis row ID immediately. The background worker opens its own DB
    connection so it can outlive the originating HTTP request.
    """
    dsn = database_url or os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL not configured")

    analysis_id, system_prompt, user_message = _create_pending_analysis(db, date_from, date_to)

    thread = threading.Thread(
        target=_execute_analysis,
        args=(analysis_id, system_prompt, user_message, dsn),
        name=f"analysis-{analysis_id}",
        daemon=True,
    )
    try:
        thread.start()
    except Exception as e:
        logging.exception("Failed to start background thread for analysis %d", analysis_id)
        _mark_analysis_failed(db, dsn, analysis_id, e)
        raise
    return analysis_id


def run_analysis(db, date_from: date, date_to: date) -> int:
    """Run a full analysis synchronously (used by tests).

    Production callers should use start_analysis() instead to avoid blocking the
    HTTP worker on the Anthropic API call.
    """
    analysis_id, system_prompt, user_message = _create_pending_analysis(db, date_from, date_to)
    try:
        _complete_analysis(db, analysis_id, system_prompt, user_message)
    except Exception as e:
        logging.exception("Analysis %d failed: %s", analysis_id, e)
        _mark_analysis_failed(db, None, analysis_id, e)
    return analysis_id


def _create_pending_analysis(db, date_from: date, date_to: date):
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    data = gather_analysis_data(cur, date_from, date_to)
    system_prompt, user_message = build_prompt(data, date_from, date_to)

    request_payload = {
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }
    cur.execute(
        "INSERT INTO analyses (date_from, date_to, status, model, request_payload, created_at) "
        "VALUES (%s, %s, 'pending', %s, %s, NOW()) RETURNING id",
        (date_from, date_to, MODEL, json.dumps(request_payload)),
    )
    analysis_id = cur.fetchone()["id"]
    db.commit()
    return analysis_id, system_prompt, user_message


def _execute_analysis(analysis_id: int, system_prompt: str, user_message: str, database_url: str) -> None:
    conn = None
    try:
        conn = psycopg2.connect(database_url)
        _complete_analysis(conn, analysis_id, system_prompt, user_message)
    except Exception as e:
        logging.exception("Background analysis %d crashed before completion", analysis_id)
        _mark_analysis_failed(conn, database_url, analysis_id, e)
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                logging.exception("Failed to close DB connection for analysis %d", analysis_id)


def _mark_analysis_failed(existing_conn, database_url, analysis_id: int, exc: Exception) -> None:
    """Best-effort update of the analyses row to 'failed'. Tries the existing connection
    first; if that's broken or missing (and a DSN is provided), opens a new one."""
    for use_new in (False, True):
        conn = None
        try:
            if use_new:
                if not database_url:
                    continue
                conn = psycopg2.connect(database_url)
                target = conn
            else:
                if existing_conn is None:
                    continue
                target = existing_conn
                try:
                    target.rollback()
                except Exception:
                    pass
            cur = target.cursor()
            cur.execute(
                "UPDATE analyses SET status = 'failed', error_message = %s, completed_at = NOW() "
                "WHERE id = %s",
                (str(exc), analysis_id),
            )
            target.commit()
            return
        except Exception:
            logging.exception(
                "Failed to mark analysis %d as failed (use_new=%s)", analysis_id, use_new
            )
        finally:
            if use_new and conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


def _complete_analysis(db, analysis_id: int, system_prompt: str, user_message: str) -> None:
    """Mark the analysis as running, call Claude, and write the result.

    Raises on any failure — callers are responsible for recording the failed state
    (see _mark_analysis_failed). Keeping this function exception-free of its own
    recovery logic means there's no risk of a partially-initialized cursor being
    used on a broken connection.
    """
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("UPDATE analyses SET status = 'running' WHERE id = %s", (analysis_id,))
    db.commit()

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
    message = client.messages.create(
        model=MODEL,
        max_tokens=16384,
        system=system_prompt,
        messages=[{"role": "user", "content": user_message}],
    )

    raw_response = message.model_dump()
    parsed = parse_response(raw_response)

    cur.execute(
        "UPDATE analyses SET status = 'completed', response_payload = %s, "
        "summary = %s, trend_direction = %s, insights = %s, "
        "tokens_in = %s, tokens_out = %s, completed_at = NOW() "
        "WHERE id = %s",
        (
            json.dumps(raw_response),
            parsed["summary"],
            parsed["trend_direction"],
            json.dumps(parsed["insights"]),
            parsed["tokens_in"],
            parsed["tokens_out"],
            analysis_id,
        ),
    )
    db.commit()


STALE_ANALYSIS_MINUTES = 15


def sweep_stale_analyses(db) -> int:
    """Flip any analyses stuck in pending/running for longer than STALE_ANALYSIS_MINUTES
    to 'failed'. Handles the case where a worker process was killed mid-analysis
    (daemon thread terminated, OOM, deploy, etc.) and the row would otherwise stay
    pending forever and the UI would spin indefinitely.

    Returns the number of rows updated.
    """
    cur = db.cursor()
    cur.execute(
        "UPDATE analyses SET status = 'failed', "
        "error_message = 'Analysis timed out — worker process likely terminated.', "
        "completed_at = NOW() "
        "WHERE status IN ('pending', 'running') "
        "AND created_at < NOW() - (%s * INTERVAL '1 minute')",
        (STALE_ANALYSIS_MINUTES,),
    )
    updated = cur.rowcount
    db.commit()
    return updated


def get_analysis(cur, analysis_id: int) -> dict | None:
    """Fetch a single analysis by ID."""
    cur.execute("SELECT * FROM analyses WHERE id = %s", (analysis_id,))
    row = cur.fetchone()
    if row is None:
        return None
    return _serialize(row)


def list_analyses(cur) -> list[dict]:
    """List all analyses, newest first."""
    cur.execute(
        "SELECT id, date_from, date_to, status, model, summary, trend_direction, "
        "insights, tokens_in, tokens_out, created_at, completed_at, error_message "
        "FROM analyses ORDER BY created_at DESC"
    )
    return [_serialize(r) for r in cur.fetchall()]
