"""AI Analysis engine — gathers data, builds prompts, calls Claude, parses results."""

import json
from datetime import date, datetime

import psycopg2.extras


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

    # Barometric readings (can be high volume — sample to 1 per hour if > 500)
    cur.execute(
        "SELECT timestamp, pressure_kpa, relative_altitude_m "
        "FROM barometric_readings "
        "WHERE timestamp::date >= %s AND timestamp::date <= %s "
        "ORDER BY timestamp",
        (date_from, date_to),
    )
    baro_rows = [_serialize(r) for r in cur.fetchall()]
    if len(baro_rows) > 500:
        step = len(baro_rows) // 500
        baro_rows = baro_rows[::step]
    data["barometric_readings"] = baro_rows

    # Current correlation engine results (context for Claude)
    cur.execute(
        "SELECT signal_name, correlation, p_value, sample_count "
        "FROM correlations ORDER BY ABS(correlation) DESC"
    )
    data["correlations"] = [_serialize(r) for r in cur.fetchall()]

    return data


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
