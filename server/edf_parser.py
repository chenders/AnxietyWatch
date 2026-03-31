"""ResMed AirSense 11 EDF file parser.

Extracts a single CPAP session summary from an EDF file found on the SD card.
Primary purpose: extract the leak 95th percentile (not available in OSCAR CSV exports).

Locates the first signal whose label contains "leak", computes the 95th percentile,
and derives session date and duration from the EDF file header. Returns at most one
session dict per file. STR.edf and detail .edf files are processed the same way;
ResMed-specific STR summary structures are not yet parsed.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


def parse_edf_file(filepath: str | Path) -> list[dict[str, Any]]:
    """Parse an EDF file and extract CPAP session data.

    Returns a list of dicts, each with:
        - date: datetime.date (calendar date of session)
        - leak_rate_95th: float (L/min)
        - total_usage_minutes: int

    Raises ImportError if pyedflib is not installed.
    """
    try:
        import pyedflib
        import numpy as np
    except ImportError as e:
        raise ImportError(
            "pyedflib and numpy are required for EDF parsing. "
            "Install with: pip install pyedflib numpy"
        ) from e

    filepath = Path(filepath)
    logger.info("Parsing EDF file: %s", filepath.name)

    reader = pyedflib.EdfReader(str(filepath))
    try:
        return _extract_sessions(reader, np)
    finally:
        reader.close()


def _extract_sessions(reader, np) -> list[dict[str, Any]]:
    """Extract session data from an opened EDF file."""
    n_signals = reader.signals_in_file
    labels = reader.getSignalLabels()

    logger.info("EDF signals (%d): %s", n_signals, labels)

    # Find the leak channel
    leak_idx = None
    for i, label in enumerate(labels):
        if "leak" in label.lower():
            leak_idx = i
            break

    if leak_idx is None:
        logger.warning("No leak channel found in EDF file (labels: %s)", labels)
        return []

    # Read leak signal and compute 95th percentile
    leak_data = reader.readSignal(leak_idx)
    if len(leak_data) == 0:
        logger.warning("Leak channel is empty")
        return []

    leak_95 = float(np.percentile(leak_data, 95))

    # Extract session date from EDF header, normalize to calendar date
    start_datetime = reader.getStartdatetime()
    session_date = start_datetime.date()

    # Duration from header
    duration_seconds = reader.getFileDuration()
    duration_minutes = int(duration_seconds / 60)

    result = {
        "date": session_date,
        "leak_rate_95th": round(leak_95, 2),
        "total_usage_minutes": duration_minutes,
    }

    logger.info(
        "Extracted: date=%s, leak_95th=%.2f, duration=%d min",
        session_date, leak_95, duration_minutes,
    )

    return [result]


def upsert_cpap_leak(conn, sessions: list[dict[str, Any]]) -> int:
    """Upsert leak data into cpap_sessions table.

    Only updates leak_rate_95th for existing rows. Inserts new rows
    with available data if no row exists for the date.

    Returns number of rows affected.
    """
    if not sessions:
        return 0

    cur = conn.cursor()
    affected = 0

    for session in sessions:
        # Ensure we have a date object, not datetime
        d = session["date"]
        if hasattr(d, "date"):
            d = d.date()
        leak = session.get("leak_rate_95th")
        duration = session.get("total_usage_minutes")

        if leak is None:
            continue

        # Try to update existing row first (from CSV import)
        cur.execute(
            "UPDATE cpap_sessions SET leak_rate_95th = %s "
            "WHERE date = %s AND leak_rate_95th IS NULL",
            (leak, d),
        )
        if cur.rowcount > 0:
            affected += cur.rowcount
            continue

        # Check if row exists at all
        cur.execute("SELECT 1 FROM cpap_sessions WHERE date = %s", (d,))
        if cur.fetchone():
            # Row exists with leak already set — skip
            continue

        # No row exists — insert with what we have
        cur.execute(
            """INSERT INTO cpap_sessions
                   (date, ahi, total_usage_minutes, leak_rate_95th,
                    import_source)
               VALUES (%s, %s, %s, %s, 'edf')
               ON CONFLICT (date) DO NOTHING""",
            (
                d,
                0.0,  # AHI unknown from detail EDF
                duration or 0,
                leak,
            ),
        )
        affected += cur.rowcount

    conn.commit()
    return affected
