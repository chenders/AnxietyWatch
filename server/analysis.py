"""AI Analysis engine — gathers data, builds prompts, calls Claude, parses results."""

import json
import os
from datetime import date, datetime

import anthropic
import psycopg2.extras

MODEL = "claude-opus-4-6"


def gather_analysis_data(cur, date_from: date, date_to: date) -> dict:
    """Query all data sources for the given date range.

    Returns a dict with keys for each data source, values are lists of dicts.
    """
    data = {}

    # Anxiety entries (join on date range via timestamp::date)
    cur.execute(
        "SELECT timestamp, severity, notes, tags FROM anxiety_entries "
        "WHERE timestamp::date >= %s AND timestamp::date <= %s "
        "ORDER BY timestamp",
        (date_from, date_to),
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
        "WHERE d.timestamp::date >= %s AND d.timestamp::date <= %s "
        "ORDER BY d.timestamp",
        (date_from, date_to),
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
        "WHERE timestamp::date >= %s AND timestamp::date <= %s "
        "ORDER BY timestamp",
        (date_from, date_to),
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
        user_parts.append(json.dumps(rows, default=str, indent=None))
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

    return {
        "summary": parsed.get("summary", ""),
        "trend_direction": parsed.get("trend_direction", "mixed"),
        "insights": parsed.get("insights", []),
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


def run_analysis(db, date_from: date, date_to: date) -> int:
    """Run a full analysis: gather data, call Claude, store results.

    Returns the analysis row ID.
    """
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Gather data
    data = gather_analysis_data(cur, date_from, date_to)

    # Build prompt
    system_prompt, user_message = build_prompt(data, date_from, date_to)

    # Insert pending row
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

    # Call Anthropic API
    try:
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
    except Exception as e:
        cur.execute(
            "UPDATE analyses SET status = 'failed', error_message = %s, completed_at = NOW() "
            "WHERE id = %s",
            (str(e), analysis_id),
        )

    db.commit()
    return analysis_id


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
