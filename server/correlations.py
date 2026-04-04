"""Correlation engine — computes Pearson correlations between physiological signals and anxiety severity."""

import numpy as np
from scipy import stats

SIGNALS = [
    ("hrv_avg", "h.hrv_avg", ["h.hrv_avg"]),
    ("resting_hr", "h.resting_hr", ["h.resting_hr"]),
    ("sleep_duration_min", "h.sleep_duration_min", ["h.sleep_duration_min"]),
    (
        "sleep_quality_ratio",
        "CASE WHEN h.sleep_duration_min > 0 "
        "THEN (COALESCE(h.sleep_deep_min, 0) + COALESCE(h.sleep_rem_min, 0))::float "
        "/ h.sleep_duration_min ELSE NULL END",
        ["h.sleep_duration_min"],
    ),
    ("steps", "h.steps", ["h.steps"]),
    ("cpap_ahi", "h.cpap_ahi", ["h.cpap_ahi"]),
    ("barometric_pressure_change_kpa", "h.barometric_pressure_change_kpa",
     ["h.barometric_pressure_change_kpa"]),
]

MINIMUM_PAIRED_DAYS = 14


def compute_correlations(cur):
    """Compute Pearson correlations for all signals. Returns list of result dicts."""
    results = []

    for signal_name, sql_expr, required_cols in SIGNALS:
        not_null = " AND ".join(f"{col} IS NOT NULL" for col in required_cols)

        cur.execute(f"""
            SELECT {sql_expr} AS signal_value, AVG(a.severity) AS avg_severity
            FROM health_snapshots h
            JOIN anxiety_entries a ON a.timestamp::date = h.date
            WHERE {not_null}
            GROUP BY h.date, {sql_expr}
            ORDER BY h.date
        """)
        rows = cur.fetchall()

        if len(rows) < MINIMUM_PAIRED_DAYS:
            continue

        signal_values = np.array([r[0] for r in rows], dtype=float)
        severity_values = np.array([r[1] for r in rows], dtype=float)

        # Skip if either array is constant — pearsonr returns NaN
        if np.std(signal_values) == 0 or np.std(severity_values) == 0:
            continue

        r, p = stats.pearsonr(signal_values, severity_values)

        mean = np.mean(signal_values)
        std = np.std(signal_values, ddof=1)
        if std > 0:
            abnormal_mask = np.abs(signal_values - mean) > std
            normal_mask = ~abnormal_mask
            mean_sev_abnormal = (
                float(np.mean(severity_values[abnormal_mask]))
                if abnormal_mask.any() else None
            )
            mean_sev_normal = (
                float(np.mean(severity_values[normal_mask]))
                if normal_mask.any() else None
            )
        else:
            mean_sev_abnormal = None
            mean_sev_normal = None

        results.append({
            "signal_name": signal_name,
            "correlation": float(r),
            "p_value": float(p),
            "sample_count": len(rows),
            "mean_severity_when_abnormal": mean_sev_abnormal,
            "mean_severity_when_normal": mean_sev_normal,
        })

    return results


def store_correlations(cur, results):
    """Upsert correlation results into the database."""
    for r in results:
        cur.execute(
            """INSERT INTO correlations
                   (signal_name, correlation, p_value, sample_count,
                    mean_severity_when_abnormal, mean_severity_when_normal,
                    computed_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW())
               ON CONFLICT (signal_name) DO UPDATE SET
                   correlation = EXCLUDED.correlation,
                   p_value = EXCLUDED.p_value,
                   sample_count = EXCLUDED.sample_count,
                   mean_severity_when_abnormal = EXCLUDED.mean_severity_when_abnormal,
                   mean_severity_when_normal = EXCLUDED.mean_severity_when_normal,
                   computed_at = EXCLUDED.computed_at""",
            (
                r["signal_name"], r["correlation"], r["p_value"],
                r["sample_count"], r["mean_severity_when_abnormal"],
                r["mean_severity_when_normal"],
            ),
        )


def get_correlations(cur):
    """Fetch all stored correlations."""
    cur.execute(
        """SELECT signal_name, correlation, p_value, sample_count,
                  mean_severity_when_abnormal, mean_severity_when_normal,
                  computed_at
           FROM correlations ORDER BY ABS(correlation) DESC"""
    )
    return [
        {
            "signal_name": r[0],
            "correlation": r[1],
            "p_value": r[2],
            "sample_count": r[3],
            "mean_severity_when_abnormal": r[4],
            "mean_severity_when_normal": r[5],
            "computed_at": r[6].isoformat() if r[6] else None,
        }
        for r in cur.fetchall()
    ]


def get_paired_day_count(cur):
    """Count days that have both a health snapshot and an anxiety entry."""
    cur.execute("""
        SELECT COUNT(DISTINCT h.date)
        FROM health_snapshots h
        JOIN anxiety_entries a ON a.timestamp::date = h.date
    """)
    return cur.fetchone()[0]


def correlations_are_stale(cur):
    """Check if correlations need recomputing (new entries or snapshots since last computation)."""
    cur.execute("SELECT MAX(computed_at) FROM correlations")
    last_computed = cur.fetchone()[0]
    if last_computed is None:
        return True

    # Stale if new anxiety entries since last computation
    cur.execute("SELECT MAX(timestamp) FROM anxiety_entries")
    last_entry = cur.fetchone()[0]
    if last_entry and last_entry > last_computed:
        return True

    # Also stale if new health snapshots (new physiological data to correlate)
    cur.execute("SELECT MAX(date) FROM health_snapshots")
    last_snapshot = cur.fetchone()[0]
    if last_snapshot and last_snapshot > last_computed.date():
        return True

    return False
