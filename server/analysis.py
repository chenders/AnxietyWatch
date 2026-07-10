"""AI Analysis engine — gathers data, builds prompts, calls Claude, parses results."""

import json
import logging
import os
import threading
from datetime import date, datetime, timedelta, timezone

from zoneinfo import ZoneInfo

import anthropic
import psycopg2
import psycopg2.extras

# Single source of truth for model options: (id, display_label, input_$/M, output_$/M)
MODEL_CHOICES = [
    ("claude-opus-4-7", "Claude Opus 4.7", 15.0, 75.0),
    ("claude-opus-4-6", "Claude Opus 4.6", 15.0, 75.0),
    ("claude-opus-4-5-20250414", "Claude Opus 4.5", 15.0, 75.0),
]
MODEL = MODEL_CHOICES[0][0]
ALLOWED_MODELS = {m[0] for m in MODEL_CHOICES}
MODEL_PRICING = {m[0]: {"input": m[2], "output": m[3]} for m in MODEL_CHOICES}


# Default timezone for analysis day-bucketing. Matches the `settings` table
# default read by _create_pending_analysis and the prompt's timezone note.
# Canonical IANA name (not the legacy "US/Pacific" alias, which the slim
# container image's tzdata omits — see _resolve_timezone).
DEFAULT_ANALYSIS_TIMEZONE = "America/Los_Angeles"

# Legacy tz aliases → canonical IANA names. The deployment image ships the
# primary IANA zones but not the backward-compatibility "US/*" aliases, so
# ZoneInfo("US/Pacific") raises even though the name is perfectly valid. These
# are known-good equivalents, not typos, so we resolve them silently rather
# than emitting the "unknown timezone" warning. A stored settings value of
# "US/Pacific" (the pre-canonicalization default) therefore resolves cleanly.
_LEGACY_TZ_ALIASES = {
    "US/Pacific": "America/Los_Angeles",
    "US/Eastern": "America/New_York",
    "US/Central": "America/Chicago",
    "US/Mountain": "America/Denver",
    "US/Arizona": "America/Phoenix",
    "US/Alaska": "America/Anchorage",
    "US/Hawaii": "Pacific/Honolulu",
}


def _resolve_timezone(tz_name: str) -> ZoneInfo:
    """Resolve an IANA timezone name defensively.

    The name comes from the user-editable `settings` table; a typo there must
    not crash analysis, so fall back to the user's actual timezone (Pacific).
    Known legacy "US/*" aliases resolve silently to their canonical IANA
    equivalent; only a genuinely-unresolvable name warns and falls back.
    """
    try:
        return ZoneInfo(tz_name)
    except (KeyError, ValueError, TypeError):
        canonical = _LEGACY_TZ_ALIASES.get(tz_name)
        if canonical is not None:
            return ZoneInfo(canonical)
        logging.warning("Unknown timezone %r — falling back to America/Los_Angeles", tz_name)
        return ZoneInfo("America/Los_Angeles")


def gather_analysis_data(cur, date_from: date, date_to: date,
                         tz_name: str = DEFAULT_ANALYSIS_TIMEZONE) -> dict:
    """Query all data sources for the given date range.

    Timestamp-filtered tables (anxiety_entries, medication_doses,
    barometric_readings, song_occurrences) use local-day boundaries in
    `tz_name` — the half-open window [date_from 00:00 local, date_to+1d 00:00
    local), DST-aware via zoneinfo, converted to UTC for the SQL comparison.
    This keeps them on the same local days as the date-keyed tables
    (health_snapshots, cpap_sessions): an entry logged 9 PM Pacific on the
    final day of the range is included, not silently dropped past a UTC
    midnight. Serialized timestamps are converted to `tz_name` so the
    prompt's "all timestamps are in <tz>" note is accurate and
    compute_effective_dates derives local calendar dates.

    Returns a dict with keys for each data source, values are lists of dicts.
    """
    data = {}
    tz = _resolve_timezone(tz_name)
    ts_start = datetime.combine(date_from, datetime.min.time(), tzinfo=tz).astimezone(timezone.utc)
    ts_end = datetime.combine(
        date_to + timedelta(days=1), datetime.min.time(), tzinfo=tz
    ).astimezone(timezone.utc)

    # Anxiety entries (half-open timestamp range for index usage)
    cur.execute(
        "SELECT timestamp, severity, notes, tags FROM anxiety_entries "
        "WHERE timestamp >= %s AND timestamp < %s "
        "ORDER BY timestamp",
        (ts_start, ts_end),
    )
    data["anxiety_entries"] = [_serialize(r, tz) for r in cur.fetchall()]

    # Health snapshots
    cur.execute(
        "SELECT * FROM health_snapshots WHERE date >= %s AND date <= %s ORDER BY date",
        (date_from, date_to),
    )
    data["health_snapshots"] = [_serialize(r, tz) for r in cur.fetchall()]

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
    data["medication_doses"] = [_serialize(r, tz) for r in cur.fetchall()]

    # CPAP sessions
    cur.execute(
        "SELECT * FROM cpap_sessions WHERE date >= %s AND date <= %s ORDER BY date",
        (date_from, date_to),
    )
    data["cpap_sessions"] = [_serialize(r, tz) for r in cur.fetchall()]

    # Barometric readings (can be high volume — downsample with a uniform stride if > 500)
    cur.execute(
        "SELECT timestamp, pressure_kpa, relative_altitude_m "
        "FROM barometric_readings "
        "WHERE timestamp >= %s AND timestamp < %s "
        "ORDER BY timestamp",
        (ts_start, ts_end),
    )
    baro_rows = [_serialize(r, tz) for r in cur.fetchall()]
    if len(baro_rows) > 500:
        step = -(-len(baro_rows) // 500)
        baro_rows = baro_rows[::step]
    data["barometric_readings"] = baro_rows

    # Current correlation engine results (context for Claude)
    cur.execute(
        "SELECT signal_name, correlation, p_value, sample_count "
        "FROM correlations ORDER BY ABS(correlation) DESC"
    )
    data["correlations"] = [_serialize(r, tz) for r in cur.fetchall()]

    # Song occurrences with song metadata
    cur.execute(
        """SELECT so.timestamp, so.source, so.notes,
                  s.title, s.artist, s.album, s.lyrics,
                  ae.severity AS anxiety_severity
           FROM song_occurrences so
           JOIN songs s ON s.id = so.song_id
           LEFT JOIN anxiety_entries ae ON ae.timestamp = so.anxiety_entry_id
           WHERE so.timestamp >= %s AND so.timestamp < %s
           ORDER BY so.timestamp""",
        (ts_start, ts_end),
    )
    data["song_occurrences"] = [_serialize(r, tz) for r in cur.fetchall()]

    # All songs (for frequency context even if no occurrences in this range)
    cur.execute(
        """SELECT s.id, s.title, s.artist, s.lyrics IS NOT NULL AS has_lyrics,
                  COUNT(so.id) AS total_occurrences,
                  COUNT(so.id) FILTER (WHERE so.timestamp >= %s AND so.timestamp < %s) AS period_occurrences,
                  AVG(ae.severity) FILTER (WHERE so.timestamp >= %s AND so.timestamp < %s) AS avg_anxiety
           FROM songs s
           LEFT JOIN song_occurrences so ON so.song_id = s.id
           LEFT JOIN anxiety_entries ae ON ae.timestamp = so.anxiety_entry_id
           GROUP BY s.id
           HAVING COUNT(so.id) > 0
           ORDER BY period_occurrences DESC, total_occurrences DESC""",
        (ts_start, ts_end, ts_start, ts_end),
    )
    data["song_summary"] = [_serialize(r, tz) for r in cur.fetchall()]

    return data


# Hard physiological limits for outlier detection.
PHYSIOLOGICAL_LIMITS = {
    "sleep_duration_min": (0, 960),
    "resting_hr": (30, 130),
    "hrv_avg": (1, 300),
    "spo2_avg": (70, 100),
    "respiratory_rate": (6, 40),
    "bp_systolic": (60, 250),
    "bp_diastolic": (30, 150),
    "blood_glucose_avg": (30, 500),
    "steps": (0, 100_000),
    "active_calories": (0, 5000),
    "exercise_minutes": (0, 480),
    "skin_temp_deviation": (-5.0, 5.0),
}

SLEEP_STAGE_FIELDS = ["sleep_deep_min", "sleep_rem_min", "sleep_core_min", "sleep_awake_min"]


def flag_outliers(data: dict) -> list[str]:
    """Check health snapshots for physiologically implausible values."""
    warnings = []
    for snapshot in data.get("health_snapshots", []):
        day = snapshot.get("date", "unknown")
        for field, (lo, hi) in PHYSIOLOGICAL_LIMITS.items():
            value = snapshot.get(field)
            if value is None:
                continue
            if value < lo:
                warnings.append(f"{day}: {field} of {value} is below minimum {lo} — likely tracking/sensor error")
            elif value > hi:
                warnings.append(f"{day}: {field} of {value} exceeds maximum {hi} — likely tracking/sensor error")
        # Sleep stage consistency
        duration = snapshot.get("sleep_duration_min")
        if duration is not None:
            stage_values = [snapshot.get(f) for f in SLEEP_STAGE_FIELDS]
            present = [v for v in stage_values if v is not None]
            if present:
                stage_total = sum(present)
                if stage_total > duration:
                    warnings.append(
                        f"{day}: sleep stages total ({stage_total} min) exceeds "
                        f"sleep_duration_min ({duration} min) — likely HealthKit stitching error"
                    )
    return warnings


def compute_effective_dates(data: dict, date_from: date, date_to: date) -> tuple[date, date]:
    """Determine the actual date range covered by the data.

    Timestamps arrive from gather_analysis_data already converted to the
    analysis timezone (offset embedded in the ISO string), so `.date()` on the
    parsed value yields the local calendar day — a 9 PM Pacific entry counts
    toward its Pacific date, not the UTC date it was stored under.
    """
    all_dates = []
    for source in ("health_snapshots", "cpap_sessions"):
        for row in data.get(source, []):
            d = row.get("date")
            if d:
                all_dates.append(date.fromisoformat(str(d)))
    for source in ("anxiety_entries", "medication_doses", "barometric_readings",
                   "song_occurrences"):
        for row in data.get(source, []):
            ts = row.get("timestamp")
            if ts:
                all_dates.append(datetime.fromisoformat(str(ts)).date())
    if not all_dates:
        return date_from, date_to
    return min(all_dates), max(all_dates)


DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


# Mirror of `DeviceProvenance.displayName(for:)` in
# `AnxietyWatch/Utilities/DeviceProvenance.swift`. Keep in sync with that file —
# any time a new bundle ID is added there, mirror it here so the Claude prompt
# renders a human-readable source name instead of a raw reverse-DNS string.
DEVICE_DISPLAY_NAMES = {
    "com.dexcom.stelo": "Stelo",
    "com.dexcom.cgm": "Dexcom",
    "com.dexcom.G6": "Dexcom G6",
    "com.dexcom.G7": "Dexcom G7",
    "com.abbottdiabetescare.libre2": "FreeStyle Libre 2",
    "com.abbottdiabetescare.libre3": "FreeStyle Libre 3",
    "com.emay.sleepo2": "EMAY SleepO2",
    "com.emay.SleepO2": "EMAY SleepO2",
    "io.wellue.health": "Wellue O2Ring",
    "com.viatomtech.wellue.O2Ring": "Wellue O2Ring",
    "com.apple.health": "Apple Watch",
    "com.apple.Health": "Apple Watch",
    "com.withings.wiscale2": "Withings",
    "com.omronhealthcare.OmronConnect": "Omron",
    "com.qardio.app": "Qardio",
}


def _device_display_name(bundle_id: str) -> str:
    """Mirror of Swift `DeviceProvenance.displayName(for:)`."""
    return DEVICE_DISPLAY_NAMES.get(bundle_id, bundle_id)


# The verbatim reliability + absence-vs-zero instruction block from the spec at
# `docs/superpowers/specs/2026-05-05-cgm-spo2-provenance-design.md`. The exact
# phrasing matters — Claude reads "absence is not zero" most reliably when the
# clinical examples are concrete.
RELIABILITY_AND_ABSENCE_INSTRUCTIONS = (
    "**Reliability tiers and absence vs. zero.** Each metric is tagged with a reliability tier based"
    " on the writing-source device and sample density.\n"
    "- `high`: dedicated continuous medical-grade device dominant. Treat as physiologically meaningful.\n"
    "- `medium`: dedicated device present but partial coverage, or mixed sources. Useful but qualify"
    " temporal claims.\n"
    "- `low`: spot/ambient sources only. Mention the source explicitly when citing the value;"
    " avoid clinical conclusions.\n"
    "- `insufficient`: do not cite the metric.\n"
    "\n"
    "**Absence of data is not the same as a zero or low value.** When a metric is missing for a"
    " period, or marked `insufficient`, the most likely explanation is a capture or sync gap — the"
    " device wasn't worn, the sensor was offline, the companion app hasn't yet pushed to HealthKit,"
    " or the iOS sync to this server is lagged. Examples:\n"
    "- SpO₂ silent overnight does **not** indicate apnea or hypoxia. The patient may simply not"
    " have worn the EMAY ring that night.\n"
    "- HR silent for hours does **not** indicate cardiac arrest. The Apple Watch was probably"
    " off-wrist or charging.\n"
    "- Glucose silent for an afternoon does **not** indicate hypoglycemia. The Stelo sensor may"
    " have been compressed, lost signal, or its app hasn't yet written the buffer to HealthKit.\n"
    "- Sleep silent for a date range does **not** mean the patient stopped sleeping. The Watch"
    " may not have been worn to bed.\n"
    "\n"
    "When a metric is missing, say so explicitly (\"no SpO₂ data captured this night\") rather"
    " than imputing a value. Distinguish \"we have data showing X\" from \"we have no data for"
    " this period.\" Do not draw clinical conclusions from absence.\n"
    "\n"
    "Full per-sample data is available server-side. If a specific clinical observation would be"
    " sharper with intraday samples (e.g., HR around an anxiety entry timestamp), request a"
    " windowed query rather than guessing from daily aggregates."
)


def _safe_int(v) -> int:
    """Coerce a value to int defensively.

    Server-side `data_quality.sources` is a JSONB blob written by the iOS
    client. Older or hand-edited rows may surface non-numeric counts; an
    `int(...)` cast in a sort key would crash the whole prompt build for
    one bad row. Treat anything we can't coerce as zero so it sorts last.
    """
    try:
        return int(v or 0)
    except (ValueError, TypeError):
        return 0


def _format_per_day_data_quality(snapshots: list[dict]) -> str:
    """Render the per-day reliability + sources block for the user message.

    Walks each `health_snapshots` row, parses the `data_quality` JSONB column
    (Postgres returns it as a Python dict; older rows have NULL), and emits a
    readable per-family `reliability:` / `sources:` block. Format mirrors the
    spec example.
    """
    lines = ["## Data quality per day"]
    for snap in snapshots:
        date_label = snap.get("date") or "unknown date"
        dq = snap.get("data_quality")
        # JSONB may surface as a dict (psycopg2 default) or as a JSON-encoded
        # string in some tests/fixtures. Normalize both.
        if isinstance(dq, str):
            try:
                dq = json.loads(dq)
            except (ValueError, TypeError):
                dq = None
        if not isinstance(dq, dict) or not dq:
            lines.append(f"\n### {date_label}")
            lines.append("  data_quality: not yet computed (older snapshot or pre-v3 client)")
            continue

        lines.append(f"\n### {date_label}")
        for family in sorted(dq.keys()):
            entry = dq[family]
            if not isinstance(entry, dict):
                continue
            reliability = entry.get("reliability", "unknown")
            sources = entry.get("sources") or {}
            if isinstance(sources, dict) and sources:
                # Sort most-frequent first, with a deterministic tiebreaker on
                # bundle ID. Without the secondary key, equal counts come back
                # in dict-insertion order — which differs between JSON producers
                # (psycopg2 dict, json.loads, hand-edited fixtures) and makes
                # the rendered prompt non-deterministic.
                rendered_sources = ", ".join(
                    f"{_device_display_name(bid)}: {_safe_int(count)}"
                    for bid, count in sorted(
                        sources.items(),
                        key=lambda kv: (-_safe_int(kv[1]), kv[0]),
                    )
                )
                sources_str = "{ " + rendered_sources + " }"
            else:
                sources_str = "not captured"
            lines.append(f"  {family}:")
            lines.append(f"    reliability: {reliability}")
            lines.append(f"    sources: {sources_str}")
    return "\n".join(lines)


# Earworm lyric inclusion budget for the analysis prompt. Lyrics are included for
# every song that has them, most-salient first (song_summary is ordered by
# occurrence count), until the total budget is reached. This replaces an earlier
# hard 5-song cap that, combined with chronological ordering, let a single
# period-dominating song (e.g. one recurring earworm) consume the entire lyric
# budget and leave every other song uninterpreted.
MAX_LYRICS_CHARS_PER_SONG = 3000
MAX_LYRICS_CHARS_TOTAL = 60000


def build_prompt(
    data: dict,
    date_from: date,
    date_to: date,
    dose_tracking_incomplete: bool = False,
    detailed_output: bool = False,
    outlier_warnings: list[str] | None = None,
    therapy_sessions: list[dict] | None = None,
    timezone: str = DEFAULT_ANALYSIS_TIMEZONE,
    patient_context: dict | None = None,
) -> tuple[str, str]:
    """Build system prompt and user message for Claude analysis.

    Returns (system_prompt, user_message).
    """
    parts = []

    parts.append(
        "You are a clinical data analyst specializing in anxiety disorder pattern recognition."
        " You are analyzing the user's personal health tracking data to find patterns, correlations,"
        " and insights that could help them understand their anxiety triggers and trends."
        " Address the user directly (you/your) — they are reading this themselves."
    )

    parts.append(
        "\n## Data Sources\n"
        "\nThe user tracks:"
        "\n- **Anxiety entries**: Timestamped severity ratings (1-10 scale), free-text notes, and tags"
        "\n- **Health snapshots**: Daily physiological data from Apple Watch — HRV, resting HR,"
        " sleep stages (deep/REM/core/awake), steps, SpO2, skin temp deviation, respiratory rate,"
        " blood pressure, blood glucose, CPAP data, barometric pressure"
        "\n- **Medication doses**: Timestamped doses with medication name, mg amount, and category"
        "\n- **CPAP sessions**: Daily sleep apnea therapy data — AHI (apnea-hypopnea index),"
        " usage minutes, leak rates, pressure stats, event breakdowns (obstructive/central/hypopnea)"
        "\n- **Barometric readings**: Atmospheric pressure (kPa) and relative altitude"
        "\n- **Correlations**: Pre-computed Pearson correlations between individual physiological"
        " signals and anxiety severity (from the app's correlation engine)"
        "\n- **Song occurrences**: Songs the user reports having stuck in their head (earworms),"
        " with timestamps, linked anxiety severity, and optionally lyrics. Songs often reflect"
        " subconscious emotional processing and can be predictive of anxiety patterns."
    )

    # -- Patient Context (optional) --
    if patient_context:
        ctx_parts = []
        name = patient_context.get("patient_name")
        summary = patient_context.get("patient_summary")
        if summary:
            if name:
                ctx_parts.append(f"**Patient:** {name} — {summary}")
            else:
                ctx_parts.append(f"**Patient:** {summary}")

        psych_summary = patient_context.get("psychiatrist_summary")
        if psych_summary:
            ctx_parts.append(f"**Psychiatrist:** {psych_summary}")

        conflict_desc = patient_context.get("active_conflict")
        if conflict_desc:
            ctx_parts.append(
                f"**Active conflict with psychiatrist:** The patient and psychiatrist are "
                f"currently in a disagreement. Description: {conflict_desc}. Factor this "
                f"into your analysis — anxiety patterns during this period may be influenced "
                f"by therapeutic relationship stress. Detailed conflict analysis will be "
                f"conducted separately."
            )

        if ctx_parts:
            parts.append("\n## Patient Context\n\n" + "\n\n".join(ctx_parts))

        # If patient has a name, instruct Claude to use it
        if name:
            parts[0] = parts[0].rstrip() + (
                f" Use the patient's name ({name}) throughout the response for readability"
                f" (e.g., \"{name}'s HRV was elevated\" rather than \"The patient's HRV"
                f" was elevated\")."
            )

    # -- Data Quality Notes (always present) --
    dq_parts = []

    if dose_tracking_incomplete:
        dq_parts.append(
            "**Medication dose tracking is incomplete.** The user's dose log has unreliable"
            " timestamps and may be missing entries. The dose log is incomplete — do NOT analyze"
            " dose-response timing or any correlation that depends on when a dose was taken"
            " relative to other events. You may note which medications appear in the data and their"
            " approximate daily frequency, but treat all intraday dose timing as unreliable and do"
            " not draw conclusions from it."
        )

    if outlier_warnings:
        dq_parts.append(
            "**The following values are flagged as physiologically implausible — likely tracking"
            " or sensor errors. Do NOT use these values for pattern analysis, correlations, or"
            " conclusions. Note their existence if relevant but treat the underlying data as"
            " unreliable for those dates/fields.**\n\n"
            + "\n".join(f"- {w}" for w in outlier_warnings)
        )

    dq_parts.append(
        "**CPAP usage:** The user wears a CPAP every night. If CPAP session data is absent"
        " for any dates in this range, it means the data has not been imported yet — do NOT"
        " interpret missing CPAP data as non-compliance or skipped therapy."
    )

    dq_parts.append(
        f"**Timezone:** All timestamps are in {timezone} time (each carries an explicit"
        f" UTC offset), and daily date buckets use {timezone} calendar days."
    )

    # Reliability tier definitions + absence-vs-zero rule (verbatim from the
    # CGM/SpO2 provenance spec). Always present so Claude has the framing
    # available regardless of whether `data_quality` is populated.
    dq_parts.append(RELIABILITY_AND_ABSENCE_INSTRUCTIONS)

    if therapy_sessions:
        lines = []
        for s in therapy_sessions:
            freq = s.get("frequency", "weekly")
            if freq == "weekly":
                dow = s.get("day_of_week")
                if dow is None or dow not in range(7):
                    continue
                day = DAY_NAMES[dow] + "s"
            elif freq == "monthly":
                dom = s.get("day_of_month")
                if dom is None:
                    continue
                day = f"day {dom}"
            else:
                continue
            time_str = str(s["time_of_day"])[:5]
            # Format time as 12-hour
            h, m = int(time_str.split(":")[0]), time_str.split(":")[1]
            ampm = "AM" if h < 12 else "PM"
            h12 = h if 1 <= h <= 12 else (h - 12 if h > 12 else 12)
            time_fmt = f"{h12}:{m} {ampm}"
            typ = "virtual/Zoom" if s["session_type"] == "virtual" else "in-person"
            commute = f", ~{s['commute_minutes']} min commute" if s.get("commute_minutes") else ""
            lines.append(f"- {day} at {time_fmt} ({typ}{commute})")
        notes = [s.get("notes") for s in therapy_sessions if s.get("notes")]
        schedule_text = "**Therapy schedule:** The patient has the following recurring appointments:\n"
        schedule_text += "\n".join(lines)
        if notes:
            schedule_text += "\nNotes: " + "; ".join(notes)
        schedule_text += (
            "\nFactor this into temporal pattern analysis — anxiety may spike before sessions,"
            " shift after sessions, or correlate with commute days."
        )
        dq_parts.append(schedule_text)

    parts.append("\n## Data Quality Notes\n\n" + "\n\n".join(dq_parts))

    goals = [
        "**Confirm or challenge suspected patterns** — validate what the data actually shows",
        "**Find non-obvious correlations** — even if potentially coincidental,"
        " include them with honest confidence scores",
        "**Detect temporal patterns** — time-of-day, day-of-week, multi-day sequences,"
        " lagged effects (e.g., poor sleep → next-day anxiety)",
    ]
    if not dose_tracking_incomplete:
        goals.append(
            "**Evaluate medication effectiveness** — dose-response patterns, timing effects, tolerance development"
        )
    goals += [
        "**Identify compound triggers** — multiple factors combining (e.g., poor sleep + low HRV + barometric drop)",
        "**Analyze earworm patterns** — correlate recurring songs with anxiety severity and timing."
        " For songs with lyrics, analyze emotional themes and what feelings they might reflect."
        " Identify songs that appear before anxiety spikes (predictive) vs. during (concurrent)"
        " vs. after (processing).",
        "**Flag anomalies** — unusual data points, sudden shifts, outliers worth investigating",
        "**Assess CPAP/sleep apnea connections** — how CPAP compliance and AHI relate to anxiety",
        "**Note environmental factors** — barometric pressure changes and their timing relative to anxiety",
    ]
    numbered_goals = "\n".join(f"{i + 1}. {g}" for i, g in enumerate(goals))
    parts.append(f"\n## Analysis Goals\n\n{numbered_goals}")

    categories = [
        "correlation", "temporal_pattern", "song_pattern", "anomaly",
        "sleep_apnea_connection", "environmental",
        "compound_trigger", "recommendation",
    ]
    if not dose_tracking_incomplete:
        categories.insert(1, "medication_effectiveness")
    category_str = ", ".join(categories)

    parts.append(
        "\n## Output Format\n"
        "\nRespond with valid JSON only. No markdown, no explanation outside the JSON.\n"
        "\n```json\n"
        "{\n"
        '  "summary": "'
        + (
            "Multi-paragraph narrative summary of findings for this period."
            " Be thorough and specific with numbers, dates, and statistical values inline."
            if detailed_output else
            "Multi-paragraph narrative summary written in plain, conversational language."
            " Describe findings clearly without listing raw data inline — keep specific numbers,"
            " dates, and measurements in each insight's supporting_data field instead."
            " Address the user directly (you/your)."
        )
        + '",\n'
        '  "trend_direction": "improving | worsening | stable | mixed",\n'
        '  "insights": [\n'
        "    {\n"
        f'      "category": "one of: {category_str}",\n'
        '      "severity": "high | medium | low",\n'
        '      "title": "Short, specific title describing the finding",\n'
        '      "detail": "'
        + (
            "Detailed explanation with specific numbers, dates, and reasoning"
            if detailed_output else
            "Clear, readable explanation of this finding in plain language."
            " Explain what it means for the user, not just what the numbers say."
            " Put the raw data points in supporting_data."
        )
        + '",\n'
        '      "confidence": 0.85,\n'
        '      "confidence_explanation": "Why this confidence level —'
        ' what would raise or lower it, sample size considerations",\n'
        '      "supporting_data": {\n'
        '        "relevant_key": "value — include the specific numbers that support this insight"\n'
        "      }\n"
        "    }\n"
        "  ]\n"
        "}\n"
        "```"
    )

    parts.append(
        "\n## Confidence Calibration\n"
        "\n- **0.9-1.0**: Very strong signal, large sample, consistent pattern, multiple confirming data points"
        "\n- **0.7-0.89**: Clear pattern with moderate sample size, or strong pattern with small sample"
        "\n- **0.5-0.69**: Suggestive pattern, small sample, or pattern with notable exceptions"
        "\n- **0.3-0.49**: Weak signal, very small sample, or speculative but worth noting"
        "\n- Below 0.3: Don't include — too speculative to be useful"
        "\n\nAlways explain what would raise or lower the confidence. Distinguish correlation from causation."
        " Note when more data would strengthen a finding."
    )

    if not detailed_output:
        parts.append(
            "\n## Writing Style\n"
            "\nWrite for a normal person, not a statistician."
            "\n- Use plain language throughout the summary and insight details."
            "\n- Instead of citing r-values or p-values inline (e.g., 'r = 0.82, p < 0.01'),"
            " describe the strength in plain terms: 'strong connection', 'closely linked',"
            " 'weak relationship', 'no clear pattern'. Put the actual r/p values in supporting_data."
            "\n- Do NOT write data-heavy sentences that list multiple dates and raw values inline."
            " Bad: 'CPAP was used on only 3 of the 18+ days: March 29 (544 min, AHI 4.07),"
            " March 30 (388 min, AHI 1.39), and April 5 (138 min, AHI 4.35).' Good: 'CPAP data"
            " was only available for 3 out of 18+ days, suggesting most sessions haven't been imported yet.'"
            "\n- Put raw numbers, specific date-by-date breakdowns, statistical values, and detailed"
            " measurements in the supporting_data field where the user can drill into them if they want."
            "\n- Technical terms like HRV, AHI, SpO2 are fine — but always explain their significance"
            " in human terms (e.g., 'your heart rate variability dropped, which often signals stress')."
        )

    parts.append(
        "\n## Philosophy\n"
        "\nCast a wide net. The user wants:"
        "\n- Validation of things they might already suspect"
        "\n- Surprising discoveries they would never think to look for"
        "\n- Coincidental correlations are OK — label them honestly and let the user investigate"
        "\n- More information is better than less — use confidence scores to help navigate"
        "\n- Err on the side of inclusion at lower confidence rather than omission"
    )

    system = "".join(parts)

    # Build user message with all the data
    user_parts = [
        f"Analyze this health tracking data from {date_from.isoformat()} to {date_to.isoformat()}.\n"
    ]

    song_keys = {"song_summary", "song_occurrences"}
    for source_name, rows in data.items():
        if source_name in song_keys:
            continue  # Handled in the dedicated Song Patterns section below
        user_parts.append(f"## {source_name}")
        user_parts.append(json.dumps(rows, default=str, separators=(",", ":")))
        user_parts.append("")

    # Per-day data quality block (reliability tiers + source breakdown).
    # Pulled from the `data_quality` JSONB column on `health_snapshots`. Older
    # snapshots without that column render as "not yet computed".
    snapshots = data.get("health_snapshots") or []
    if snapshots:
        user_parts.append(_format_per_day_data_quality(snapshots))
        user_parts.append("")

    # Song patterns section
    song_summary = data.get("song_summary", [])
    song_occurrences = data.get("song_occurrences", [])
    if song_summary:
        user_parts.append("## Song Patterns (Earworms)\n")
        user_parts.append(json.dumps(song_summary, indent=2, default=str))

        # Map each in-range song to its lyrics (first occurrence that carries them).
        lyrics_by_title = {}
        for occ in song_occurrences:
            if occ.get("lyrics"):
                title_key = f"{occ['title']} — {occ['artist']}"
                lyrics_by_title.setdefault(title_key, occ["lyrics"])

        # Include lyrics for every song that has them, most-salient first.
        # song_summary is ordered by occurrence count, so the budget is spent on the
        # songs that matter most; the total-character cap keeps the prompt bounded
        # when many distinct songs appear. No per-song-count cap — a single recurring
        # earworm no longer crowds every other song out of the analysis.
        lyrics_chars_used = 0
        lyrics_omitted = []
        for s in song_summary:
            title_key = f"{s['title']} — {s['artist']}"
            full_lyrics = lyrics_by_title.get(title_key)
            if not full_lyrics:
                continue
            lyrics = full_lyrics[:MAX_LYRICS_CHARS_PER_SONG]
            if len(full_lyrics) > MAX_LYRICS_CHARS_PER_SONG:
                lyrics += "\n[lyrics truncated]"
            # Check the budget against what this song would add BEFORE
            # appending, so the total can never overshoot the cap.
            if lyrics_chars_used + len(lyrics) > MAX_LYRICS_CHARS_TOTAL:
                lyrics_omitted.append(title_key)
                continue
            user_parts.append(f"\n### {title_key}\nLyrics:\n{lyrics}\n")
            lyrics_chars_used += len(lyrics)
        if lyrics_omitted:
            user_parts.append(
                "\nLyrics for these songs were omitted only to keep the prompt within budget"
                " (their titles and occurrence counts are in the summary above; analyze them"
                f" from that data and web search if useful): {', '.join(lyrics_omitted)}\n"
            )

        # For songs without lyrics that show interesting patterns, instruct Claude to search
        songs_needing_lookup = [
            s for s in song_summary
            if not s.get("has_lyrics") and (
                s.get("period_occurrences", 0) >= 3
                or (s.get("avg_anxiety") and s["avg_anxiety"] >= 6)
            )
        ]
        if songs_needing_lookup:
            titles = [f"'{s['title']}' by {s['artist']}" for s in songs_needing_lookup]
            user_parts.append(
                f"\nThe following songs lack stored lyrics but show notable patterns."
                f" Use web search to find and analyze their lyrics: {', '.join(titles)}\n"
            )
    elif song_occurrences:
        user_parts.append("## Song Occurrences\n")
        user_parts.append(json.dumps(song_occurrences, indent=2, default=str))

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


def _serialize(row, tz: ZoneInfo | None = None):
    """Convert a RealDictRow to a plain dict with JSON-safe values.

    When `tz` is given, timezone-aware datetimes are converted to that zone
    before ISO-formatting, so the analysis payload's timestamps read as local
    wall-clock times (with explicit UTC offset) instead of whatever timezone
    the DB session happens to use (UTC in the Docker deployment). Naive
    datetimes are formatted as-is.
    """
    result = {}
    for k, v in row.items():
        if isinstance(v, datetime):
            if tz is not None and v.tzinfo is not None:
                v = v.astimezone(tz)
            result[k] = v.isoformat()
        elif isinstance(v, date):
            result[k] = v.isoformat()
        else:
            result[k] = v
    return result


def start_analysis(
    db, date_from: date, date_to: date,
    database_url: str | None = None,
    dose_tracking_incomplete: bool = False,
    detailed_output: bool = False,
    model: str | None = None,
    include_conflict: bool = True,
) -> int:
    """Create a pending analysis row, create jobs, and dispatch in background.

    Returns the analysis row ID immediately.
    """
    dsn = database_url or os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL not configured")

    effective_model = model or MODEL

    analysis_id, _, _ = _create_pending_analysis(
        db, date_from, date_to,
        dose_tracking_incomplete=dose_tracking_incomplete,
        detailed_output=detailed_output,
        model=effective_model,
        include_conflict=include_conflict,
    )

    # Create jobs via dispatcher (inline import to avoid circular dependency)
    from job_dispatcher import create_analysis_jobs, dispatch_analysis
    create_analysis_jobs(db, analysis_id, include_conflict=include_conflict, model=effective_model)

    thread = threading.Thread(
        target=dispatch_analysis,
        args=(analysis_id, dsn),
        name=f"analysis-{analysis_id}",
        daemon=True,
    )
    try:
        thread.start()
    except Exception as e:
        logging.exception("Failed to start dispatch thread for analysis %d", analysis_id)
        _mark_analysis_failed(db, dsn, analysis_id, e)
        raise
    return analysis_id


def run_analysis(db, date_from: date, date_to: date,
                 dose_tracking_incomplete: bool = False,
                 detailed_output: bool = False) -> int:
    """Run a full analysis synchronously (used by tests).

    Production callers should use start_analysis() instead to avoid blocking the
    HTTP worker on the Anthropic API call.
    """
    analysis_id, system_prompt, user_message = _create_pending_analysis(
        db, date_from, date_to,
        dose_tracking_incomplete=dose_tracking_incomplete,
        detailed_output=detailed_output,
    )
    try:
        _complete_analysis(db, analysis_id, system_prompt, user_message)
    except Exception as e:
        logging.exception("Analysis %d failed: %s", analysis_id, e)
        _mark_analysis_failed(db, None, analysis_id, e)
    return analysis_id


def _create_pending_analysis(db, date_from: date, date_to: date, dose_tracking_incomplete: bool = False,
                             detailed_output: bool = False, model: str | None = None,
                             include_conflict: bool = True):
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Read timezone setting (default America/Los_Angeles) BEFORE gathering:
    # the timestamp-range windows and serialized timestamps are bucketed by
    # local day in this timezone.
    cur.execute("SELECT value FROM settings WHERE key = 'timezone'")
    tz_row = cur.fetchone()
    # Resolve once and pass the RESOLVED canonical name everywhere: if the
    # settings value is a typo, gather_analysis_data would silently fall back
    # to America/Los_Angeles while the prompt still claimed timestamps were
    # in the typo'd zone — a prompt/data mismatch.
    tz = str(_resolve_timezone(tz_row["value"] if tz_row else DEFAULT_ANALYSIS_TIMEZONE))

    data = gather_analysis_data(cur, date_from, date_to, tz_name=tz)

    # -- Data quality enrichment --
    outlier_warnings = flag_outliers(data)
    effective_from, effective_to = compute_effective_dates(data, date_from, date_to)

    # Read active therapy sessions
    cur.execute(
        "SELECT frequency, day_of_week, day_of_month, time_of_day, "
        "session_type, commute_minutes, notes "
        "FROM therapy_sessions WHERE is_active = TRUE ORDER BY time_of_day"
    )
    therapy_rows = [dict(r) for r in cur.fetchall()]

    # Read patient context (profiles + active conflict).
    # Include context when any of the three sources is available.
    cur.execute("SELECT name, profile_summary FROM patient_profile LIMIT 1")
    patient_row = cur.fetchone()

    cur.execute("SELECT profile_summary FROM psychiatrist_profile LIMIT 1")
    psych_row = cur.fetchone()

    # Only include conflict context in the health prompt when conflict
    # analysis is also being run; otherwise the prompt would reference
    # a "separate conflict analysis" that won't actually happen.
    active_conflict = None
    if include_conflict:
        cur.execute(
            "SELECT description FROM conflicts WHERE status = 'active' "
            "ORDER BY created_at DESC LIMIT 1"
        )
        conflict_row = cur.fetchone()
        active_conflict = conflict_row.get("description") if conflict_row else None

    patient_summary = patient_row.get("profile_summary") if patient_row else None
    psychiatrist_summary = psych_row.get("profile_summary") if psych_row else None

    patient_context = None
    if patient_summary or psychiatrist_summary or active_conflict:
        patient_context = {
            "patient_name": patient_row.get("name") if patient_row else None,
            "patient_summary": patient_summary,
            "psychiatrist_summary": psychiatrist_summary,
            "active_conflict": active_conflict,
        }

    system_prompt, user_message = build_prompt(
        data, effective_from, effective_to,
        dose_tracking_incomplete=dose_tracking_incomplete,
        detailed_output=detailed_output,
        outlier_warnings=outlier_warnings if outlier_warnings else None,
        therapy_sessions=therapy_rows if therapy_rows else None,
        timezone=tz,
        patient_context=patient_context,
    )

    request_payload = {
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }
    cur.execute(
        "INSERT INTO analyses (date_from, date_to, status, model, request_payload, "
        "dose_tracking_incomplete, created_at) "
        "VALUES (%s, %s, 'pending', %s, %s, %s, NOW()) RETURNING id",
        (date_from, date_to, model or MODEL, json.dumps(request_payload), dose_tracking_incomplete),
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
SWEEP_THROTTLE_SECONDS = 60

_sweep_lock = threading.Lock()
_last_sweep_monotonic: float = 0.0


def sweep_stale_analyses(db, force: bool = False) -> int:
    """Flip any analyses stuck in pending/running for longer than STALE_ANALYSIS_MINUTES
    to 'failed'. Handles the case where a worker process was killed mid-analysis
    (daemon thread terminated, OOM, deploy, etc.) and the row would otherwise stay
    pending forever and the UI would spin indefinitely.

    Throttled to at most once per SWEEP_THROTTLE_SECONDS per process so the auto-
    refreshing detail page doesn't issue a table-wide UPDATE every 5s. Pass
    force=True to bypass the throttle (used by tests).

    Returns the number of rows updated, or 0 if the sweep was throttled.
    """
    global _last_sweep_monotonic
    import time as _time
    if not force:
        with _sweep_lock:
            now = _time.monotonic()
            if now - _last_sweep_monotonic < SWEEP_THROTTLE_SECONDS:
                return 0
            _last_sweep_monotonic = now

    # Time out from the most recent SIGN OF LIFE, not created_at: a legitimate
    # multi-job DAG (health analysis + 4 web-search research jobs on a 2-worker
    # pool + synthesis) can run well past STALE_ANALYSIS_MINUTES of wall clock
    # while jobs are actively starting and completing. Keying the timeout off
    # created_at falsely failed such runs at minute 15 while they were still
    # progressing (F-053). GREATEST(analyses.created_at, latest job start/finish)
    # only trips when NOTHING has advanced for the whole window — the real
    # "worker died" signal. Analyses with no jobs fall back to created_at.
    #
    # NULL handling: Postgres GREATEST/LEAST *ignore* NULL arguments (unlike
    # MySQL/standard SQL, which NULL-propagate) — the result is NULL only if
    # ALL arguments are NULL. analysis_jobs.created_at is NOT NULL, so the
    # inner GREATEST always has a non-NULL member: a running job (completed_at
    # NULL) still contributes started_at/created_at, and a pending job
    # contributes created_at. So a live-but-slow job's activity is never lost.
    # (test_sweep_fails_dag_with_no_recent_job_activity exercises a running,
    # completed_at-NULL job; test_sweep_does_not_fail_recently_active_dag a
    # completed one.)
    cur = db.cursor()
    cur.execute(
        "UPDATE analyses a SET status = 'failed', "
        "error_message = 'Analysis timed out — worker process likely terminated.', "
        "completed_at = NOW() "
        "WHERE a.status IN ('pending', 'running') "
        "AND GREATEST("
        "    a.created_at, "
        "    COALESCE(("
        "        SELECT MAX(GREATEST(j.started_at, j.completed_at, j.created_at)) "
        "        FROM analysis_jobs j WHERE j.analysis_id = a.id"
        "    ), a.created_at)"
        ") < NOW() - (%s * INTERVAL '1 minute')",
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
        "insights, tokens_in, tokens_out, created_at, completed_at, error_message, "
        "dose_tracking_incomplete "
        "FROM analyses ORDER BY created_at DESC"
    )
    return [_serialize(r) for r in cur.fetchall()]
