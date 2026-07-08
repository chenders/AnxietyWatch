"""Correlation engine — computes Pearson correlations between physiological signals and anxiety severity."""

import numpy as np
from scipy import stats

from analysis import DEFAULT_ANALYSIS_TIMEZONE, _resolve_timezone

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

MINIMUM_PAIRED_DAYS = 12

# settings-table key for the staleness fingerprint written by store_correlations.
STALENESS_FINGERPRINT_KEY = "correlations_fingerprint"


def resolve_analysis_timezone(cur):
    """Read the settings-driven analysis timezone (canonical IANA name).

    Reuses analysis._resolve_timezone so correlation day-bucketing follows the
    exact same settings key + fallback the analysis prompt uses — a divergence
    would silently bucket the two pipelines onto different calendar days.
    """
    cur.execute("SELECT value FROM settings WHERE key = 'timezone'")
    row = cur.fetchone()
    return str(_resolve_timezone(row[0] if row else DEFAULT_ANALYSIS_TIMEZONE))


def compute_correlations(cur, tz_name=DEFAULT_ANALYSIS_TIMEZONE):
    """Compute Pearson correlations for all signals. Returns list of result dicts.

    *tz_name* is the local timezone for day-bucketing (pass the value from
    resolve_analysis_timezone). anxiety_entries.timestamp is TIMESTAMPTZ, so
    `AT TIME ZONE <zone>` converts it to local wall-clock time before the
    ::date cast — a bare `timestamp::date` would cast in the DB session
    timezone (UTC in deployment), pairing a 9 PM Pacific entry with the NEXT
    day's snapshot.
    """
    results = []

    for signal_name, sql_expr, required_cols in SIGNALS:
        not_null = " AND ".join(f"{col} IS NOT NULL" for col in required_cols)

        cur.execute(f"""
            SELECT {sql_expr} AS signal_value, AVG(a.severity) AS avg_severity
            FROM health_snapshots h
            JOIN anxiety_entries a ON (a.timestamp AT TIME ZONE %s)::date = h.date
            WHERE {not_null}
            GROUP BY h.date, {sql_expr}
            ORDER BY h.date
        """, (tz_name,))
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


def store_correlations(cur, results, fingerprint=None):
    """Upsert correlation results and record the staleness fingerprint.

    *fingerprint* should be captured (via compute_staleness_fingerprint)
    BEFORE compute_correlations runs: a row inserted mid-computation is then
    still detected as a change on the next staleness check, instead of being
    baked into the fingerprint without being part of the results. Falls back
    to computing it at store time when not provided.
    """
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

    if fingerprint is None:
        fingerprint = compute_staleness_fingerprint(cur)
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        (STALENESS_FINGERPRINT_KEY, fingerprint),
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


def get_paired_day_count(cur, tz_name=DEFAULT_ANALYSIS_TIMEZONE):
    """Count days that have both a health snapshot and an anxiety entry.

    Same local-day bucketing as compute_correlations (see its docstring for
    the AT TIME ZONE rationale) — the two must agree or the MINIMUM_PAIRED_DAYS
    gate could pass while the compute query finds fewer pairs, or vice versa.
    """
    cur.execute("""
        SELECT COUNT(DISTINCT h.date)
        FROM health_snapshots h
        JOIN anxiety_entries a ON (a.timestamp AT TIME ZONE %s)::date = h.date
    """, (tz_name,))
    return cur.fetchone()[0]


def compute_staleness_fingerprint(cur):
    """Fingerprint of the correlation inputs: row counts + max watermarks.

    The counts are the point (F-069): a backfilled entry or snapshot dated
    BEFORE the current MAX moves neither watermark, so a max-only check never
    triggers a recompute and correlations keep ignoring the imported history.
    Counts catch backfills; the maxes stay in the fingerprint so an append
    that replaces a deleted row (count unchanged) is still detected.
    """
    cur.execute("SELECT COUNT(*), MAX(timestamp) FROM anxiety_entries")
    entry_count, entry_max = cur.fetchone()
    cur.execute("SELECT COUNT(*), MAX(date) FROM health_snapshots")
    snapshot_count, snapshot_max = cur.fetchone()
    return "|".join([
        str(entry_count),
        entry_max.isoformat() if entry_max else "",
        str(snapshot_count),
        snapshot_max.isoformat() if snapshot_max else "",
    ])


def correlations_are_stale(cur):
    """Check if correlations need recomputing (inputs changed since last computation).

    Compares the stored fingerprint (written by store_correlations) against
    the current one. A missing fingerprint — never computed, or a deployment
    that predates fingerprinting — reads as stale so the first check after
    upgrade recomputes and stores one.
    """
    cur.execute(
        "SELECT value FROM settings WHERE key = %s", (STALENESS_FINGERPRINT_KEY,)
    )
    row = cur.fetchone()
    if row is None:
        return True
    return row[0] != compute_staleness_fingerprint(cur)
