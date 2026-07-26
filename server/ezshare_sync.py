"""Sync CLI: pull the ez Share card's STR.EDF, parse it, upsert cpap_sessions.

Cron-invoked. Connects to Postgres directly via DATABASE_URL (outside Flask),
mirroring resmed_sync.py. STR.EDF is the cumulative daily summary, so every run
re-parses the whole file and upserts all day-rows — idempotent and self-healing,
which sidesteps the incremental-sync cursor race entirely (nothing is ever the
"only copy" left out of a payload). ezshare_last_sync is recorded for status
visibility only.

Precedence: ez Share (a direct SD read) overwrites resmed_cloud and its own
rows, but never clobbers a user-curated manual sd_card/csv import.

Exit codes: 0 success or AP-unreachable no-op, 2 fetch/parse error, 3 config.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import tempfile
from datetime import date, timedelta

import psycopg2

from ezshare_client import EzShareClient, EzShareUnreachable, EzShareError
from ezshare_parser import parse_str_edf
from ezshare_clock import (
    is_epoch_reset, compute_offset_days, apply_offset, offset_is_sane,
)

logger = logging.getLogger(__name__)

EZSHARE_SOURCE = "ezshare"

# ez Share overwrites cloud + its own rows; manual imports are preserved.
_SKIP_SOURCES = ("sd_card", "csv")

# Column order for the values tuple below — MUST match _UPSERT_SQL's VALUES.
_COLS = ("date", "ahi", "total_usage_minutes", "obstructive_events",
         "central_events", "hypopnea_events", "rdi_events", "rera_events",
         "pressure_min", "pressure_max", "pressure_mean", "pressure_95th",
         "leak_avg", "leak_max", "leak_rate_95th", "spo2_avg", "spo2_min",
         "pulse_avg")

# Static SQL (no string interpolation) — values are always bound via %s. The
# ON CONFLICT WHERE clause enforces precedence: only resmed_cloud/ezshare rows
# are overwritten, so a manual sd_card/csv import is never regressed.
_UPSERT_SQL = (
    "INSERT INTO cpap_sessions "
    "(date, ahi, total_usage_minutes, obstructive_events, central_events, "
    "hypopnea_events, rdi_events, rera_events, pressure_min, pressure_max, "
    "pressure_mean, pressure_95th, leak_avg, leak_max, leak_rate_95th, "
    "spo2_avg, spo2_min, pulse_avg, import_source) "
    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
    "ON CONFLICT (date) DO UPDATE SET "
    "ahi = EXCLUDED.ahi, total_usage_minutes = EXCLUDED.total_usage_minutes, "
    "obstructive_events = EXCLUDED.obstructive_events, "
    "central_events = EXCLUDED.central_events, "
    "hypopnea_events = EXCLUDED.hypopnea_events, "
    "rdi_events = EXCLUDED.rdi_events, rera_events = EXCLUDED.rera_events, "
    "pressure_min = EXCLUDED.pressure_min, pressure_max = EXCLUDED.pressure_max, "
    "pressure_mean = EXCLUDED.pressure_mean, pressure_95th = EXCLUDED.pressure_95th, "
    "leak_avg = EXCLUDED.leak_avg, leak_max = EXCLUDED.leak_max, "
    "leak_rate_95th = EXCLUDED.leak_rate_95th, spo2_avg = EXCLUDED.spo2_avg, "
    "spo2_min = EXCLUDED.spo2_min, pulse_avg = EXCLUDED.pulse_avg, "
    "import_source = EXCLUDED.import_source "
    "WHERE cpap_sessions.import_source IN ('resmed_cloud', 'ezshare')"
)


# ---------------------------------------------------------------------------
# DB helpers (self-contained — no coupling to resmed_sync's import chain)
# ---------------------------------------------------------------------------


def get_db():
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL environment variable is not set")
    return psycopg2.connect(dsn)


def get_setting(conn, key):
    cur = conn.cursor()
    cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
    row = cur.fetchone()
    return row[0] if row else None


def set_setting(conn, key, value):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        (key, value),
    )
    conn.commit()


def log_sync(conn, upserted, parsed):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id) "
        "VALUES ('ezshare', 'ezshare_sd', %s::jsonb, NULL)",
        (json.dumps({"upserted": upserted, "parsed": parsed}),),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Upsert with precedence
# ---------------------------------------------------------------------------


def upsert_ezshare_sessions(conn, sessions: list[dict]) -> int:
    """Upsert full-detail sessions. Overwrites resmed_cloud/ezshare, skips manual."""
    if not sessions:
        return 0
    cur = conn.cursor()
    affected = 0
    for s in sessions:
        cur.execute("SELECT import_source FROM cpap_sessions WHERE date = %s", (s["date"],))
        existing = cur.fetchone()
        if existing and existing[0] in _SKIP_SOURCES:
            logger.debug("Skipping %s — manual %s import exists", s["date"], existing[0])
            continue
        cur.execute(_UPSERT_SQL, tuple(s.get(c) for c in _COLS) + (EZSHARE_SOURCE,))
        affected += cur.rowcount
    conn.commit()
    return affected


# ---------------------------------------------------------------------------
# Clock-reset correction
# ---------------------------------------------------------------------------


def _correct_clock(conn, sessions):
    """Remap epoch-reset (~2008) dates to real dates via a persisted offset.

    No-op once the machine's clock is correct (dates already plausible). The
    offset is anchored to today's date on first detection and reused thereafter
    so date assignment is stable (date is the cpap_sessions primary key). If the
    persisted offset later stops making sense (a second reset, or the machine
    finally synced to AirView), it is re-established. See ezshare_clock.

    Anchor caveat: the newest raw session is mapped to *today*, which assumes a
    morning-after poll of last night's session; the result can be off by ~1 day
    depending on poll timing. Adjust the ezshare_clock_offset_days setting by
    +/-1 if the corrected dates are consistently a day out.
    """
    if not is_epoch_reset(sessions):
        return sessions
    today = date.today()
    persisted = get_setting(conn, "ezshare_clock_offset_days")
    offset = None
    if persisted is not None:
        try:
            cand = int(persisted)
        except ValueError:
            cand = None
        if cand is not None and offset_is_sane(sessions, cand, today):
            offset = cand
    if offset is None:
        offset = compute_offset_days(sessions, today)
        set_setting(conn, "ezshare_clock_offset_days", str(offset))
        logger.warning("AS11 clock reset detected — offset (re)established: %+d days", offset)
    raw_newest = max(s["date"] for s in sessions)
    corrected = apply_offset(sessions, offset)
    new_newest = raw_newest + timedelta(days=offset)
    set_setting(conn, "ezshare_clock_corrected", f"+{offset}d ({raw_newest} -> {new_newest})")
    logger.info("Clock correction applied: +%d days (%s -> %s)", offset, raw_newest, new_newest)
    return corrected


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    argparse.ArgumentParser(description="Sync ez Share CPAP data").parse_args(argv)

    try:
        conn = get_db()
    except RuntimeError as exc:
        logger.error("%s", exc)
        return 3

    base_url = get_setting(conn, "ezshare_bridge_url") or "http://192.168.4.1"
    client = EzShareClient(base_url=base_url)

    try:
        client.version()  # probe — raises EzShareUnreachable if the AP is down
    except EzShareUnreachable:
        logger.info("ez Share AP unreachable (CPAP off / out of range) — no-op")
        set_setting(conn, "ezshare_last_status", "unreachable")
        conn.close()
        return 0

    try:
        data = client.download_str_edf()
    except EzShareError as exc:
        logger.error("ez Share fetch failed: %s", exc)
        set_setting(conn, "ezshare_last_status", f"error: {exc}")
        conn.close()
        return 2

    if data is None:
        logger.warning("No STR.EDF on the card yet")
        set_setting(conn, "ezshare_last_status", "no STR.EDF on card")
        conn.close()
        return 0

    path = os.path.join(tempfile.gettempdir(), "ezshare_STR.EDF")
    with open(path, "wb") as f:
        f.write(data)
    sessions = parse_str_edf(path)
    sessions = _correct_clock(conn, sessions)

    count = upsert_ezshare_sessions(conn, sessions)
    log_sync(conn, count, len(sessions))
    set_setting(conn, "ezshare_last_status", f"ok: {count} upserted / {len(sessions)} parsed")
    if sessions:
        set_setting(conn, "ezshare_last_sync", max(str(s["date"]) for s in sessions))
    logger.info("ez Share sync complete: %d upserted (%d parsed)", count, len(sessions))
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
