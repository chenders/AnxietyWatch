"""Standalone CLI script for syncing ResMed myAir CPAP data into PostgreSQL.

Reads encrypted credentials from the settings table, fetches session data
via the myAir API, and upserts into cpap_sessions.  SD-card imports are
never overwritten; existing resmed_cloud rows are refreshed.

Exit codes:
    0  success
    1  authentication failure
    2  API / network error
    3  credentials/config error (no credentials, missing SECRET_KEY, or decrypt failure)
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from datetime import datetime, timezone

import psycopg2

from crypto import decrypt_value
from resmed_client import MyAirClient, MyAirAuthError, MyAirAPIError

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------


def get_db():
    """Connect to PostgreSQL using DATABASE_URL."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL environment variable is not set")
    return psycopg2.connect(dsn)


def get_setting(conn, key):
    """Read a single value from the settings table, or None if missing."""
    cur = conn.cursor()
    cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
    row = cur.fetchone()
    return row[0] if row else None


def set_setting(conn, key, value):
    """Upsert a value into the settings table."""
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO settings (key, value) VALUES (%s, %s) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        (key, value),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Schedule check
# ---------------------------------------------------------------------------


def should_run_now(sync_time_str, current_hour):
    """Return True if *current_hour* matches the hour in *sync_time_str*.

    *sync_time_str* may be ``"HH"`` or ``"HH:MM"``.  Only the hour part is
    compared — minute granularity is ignored (the cron job runs hourly).
    Returns False for None, empty, or unparseable values.
    """
    if not sync_time_str:
        return False
    try:
        hour = int(sync_time_str.split(":")[0])
    except (ValueError, IndexError):
        return False
    return hour == current_hour


# ---------------------------------------------------------------------------
# Core upsert logic
# ---------------------------------------------------------------------------


def upsert_sessions(conn, sessions):
    """Insert or update CPAP sessions from the myAir API.

    - Rows with ``import_source = 'sd_card'`` are never overwritten.
    - Rows with ``import_source = 'resmed_cloud'`` are updated in place.
    - New dates are inserted with ``import_source = 'resmed_cloud'``.

    Returns the number of rows inserted or updated.
    """
    if not sessions:
        return 0

    cur = conn.cursor()
    upserted = 0

    for session in sessions:
        date = session["date"]
        ahi = session["ahi"]
        usage = session["total_usage_minutes"]
        leak = session.get("leak_percentile")
        pressure = session.get("mean_pressure")

        # Check if an sd_card row already exists — skip if so
        cur.execute(
            "SELECT import_source FROM cpap_sessions WHERE date = %s",
            (date,),
        )
        existing = cur.fetchone()
        if existing and existing[0] == "sd_card":
            logger.debug("Skipping %s — sd_card import exists", date)
            continue

        # INSERT ... ON CONFLICT upsert, but only update if the existing
        # row was from resmed_cloud (the sd_card check above already
        # guards against overwriting, but the WHERE clause is belt-and-
        # suspenders safety).
        cur.execute(
            "INSERT INTO cpap_sessions "
            "  (date, ahi, total_usage_minutes, leak_rate_95th, pressure_mean, import_source) "
            "VALUES (%s, %s, %s, %s, %s, 'resmed_cloud') "
            "ON CONFLICT (date) DO UPDATE SET "
            "  ahi = EXCLUDED.ahi, "
            "  total_usage_minutes = EXCLUDED.total_usage_minutes, "
            "  leak_rate_95th = EXCLUDED.leak_rate_95th, "
            "  pressure_mean = EXCLUDED.pressure_mean, "
            "  import_source = EXCLUDED.import_source "
            "WHERE cpap_sessions.import_source = 'resmed_cloud'",
            (date, ahi, usage, leak, pressure),
        )
        # rowcount is 1 for insert or update, 0 if ON CONFLICT … WHERE filtered it out
        upserted += cur.rowcount

    conn.commit()
    return upserted


# ---------------------------------------------------------------------------
# Sync-log helper
# ---------------------------------------------------------------------------


def log_sync(conn, status, count):
    """Write an entry to sync_log and update resmed_last_status setting."""
    now = datetime.now(timezone.utc).isoformat()
    set_setting(conn, "resmed_last_sync", now)
    set_setting(conn, "resmed_last_status", f"{status}: {count} sessions upserted" if status == "success" else status)

    cur = conn.cursor()
    cur.execute(
        "INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id) "
        "VALUES (%s, %s, %s::jsonb, %s)",
        (
            "resmed_cloud",
            "resmed_myair",
            f'{{"status": "{status}", "upserted": {count}}}',
            None,
        ),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sync ResMed myAir CPAP data")
    parser.add_argument(
        "--check-schedule",
        action="store_true",
        help="Only run if the current hour matches resmed_sync_time setting",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    conn = get_db()

    # --- Schedule gate -------------------------------------------------------
    if args.check_schedule:
        sync_time = get_setting(conn, "resmed_sync_time")
        current_hour = datetime.now(timezone.utc).hour
        if not should_run_now(sync_time, current_hour):
            logger.info(
                "Skipping — current hour %d does not match sync time %r",
                current_hour,
                sync_time,
            )
            conn.close()
            return 0

    # --- Read credentials ----------------------------------------------------
    username = get_setting(conn, "resmed_email")
    encrypted_pw = get_setting(conn, "resmed_password")
    secret_key = os.environ.get("SECRET_KEY", "")
    if not secret_key:
        logger.error("SECRET_KEY env var is not set — cannot decrypt credentials")
        conn.close()
        return 3

    if not username or not encrypted_pw:
        logger.error("ResMed credentials not configured in settings table")
        log_sync(conn, "no_credentials", 0)
        conn.close()
        return 3

    try:
        password = decrypt_value(encrypted_pw, secret_key)
    except Exception:
        logger.exception("Failed to decrypt ResMed password")
        log_sync(conn, "decrypt_error", 0)
        conn.close()
        return 3

    # --- Determine lookback --------------------------------------------------
    last_sync = get_setting(conn, "resmed_last_sync")
    days = 7 if last_sync else 365

    # --- Fetch from myAir ----------------------------------------------------
    try:
        client = MyAirClient(username=username, password=password)
        sessions = asyncio.run(client.fetch_sessions(days=days))
    except MyAirAuthError as exc:
        logger.error("myAir authentication failed: %s", exc)
        log_sync(conn, "auth_error", 0)
        conn.close()
        return 1
    except MyAirAPIError as exc:
        logger.error("myAir API error: %s", exc)
        log_sync(conn, "api_error", 0)
        conn.close()
        return 2

    # --- Upsert into DB ------------------------------------------------------
    count = upsert_sessions(conn, sessions)
    log_sync(conn, "success", count)

    logger.info("Sync complete: %d sessions upserted (%d fetched)", count, len(sessions))
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
