"""Standalone CLI script for syncing Walgreens prescription data into PostgreSQL.

Reads encrypted credentials from the settings table, fetches prescription
records via the Walgreens website API, and upserts into prescriptions.
Manually-entered prescriptions are never overwritten.

Exit codes:
    0  success
    1  authentication failure
    2  API / network error
    3  credentials/config error
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from datetime import datetime, timezone, timedelta

import psycopg2

from crypto import decrypt_value
from walgreens_client import (
    WalgreensClient,
    WalgreensAuthError,
    WalgreensAPIError,
)

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
    compared.  Returns False for None, empty, or unparseable values.
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


def upsert_prescriptions(conn, prescriptions):
    """Insert or update prescriptions from the Walgreens API.

    - Rows with ``import_source = 'manual'`` are never overwritten.
    - Rows with ``import_source = 'walgreens'`` are updated in place.
    - New rx_numbers are inserted with ``import_source = 'walgreens'``.

    Returns the number of rows inserted or updated.
    """
    if not prescriptions:
        return 0

    cur = conn.cursor()
    upserted = 0

    for rx in prescriptions:
        rx_number = rx["rx_number"]

        # Check if a manual row already exists — skip if so
        cur.execute(
            "SELECT import_source FROM prescriptions WHERE rx_number = %s",
            (rx_number,),
        )
        existing = cur.fetchone()
        if existing and existing[0] == "manual":
            logger.debug("Skipping %s — manual entry exists", rx_number)
            continue

        cur.execute(
            """INSERT INTO prescriptions
                   (rx_number, medication_name, dose_mg, dose_description,
                    quantity, refills_remaining, date_filled, estimated_run_out_date,
                    pharmacy_name, notes, daily_dose_count,
                    prescriber_name, ndc_code, rx_status, last_fill_date,
                    import_source, walgreens_rx_id, directions)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                       %s, %s, %s, %s, 'walgreens', %s, %s)
               ON CONFLICT (rx_number) DO UPDATE SET
                   medication_name = EXCLUDED.medication_name,
                   dose_mg = EXCLUDED.dose_mg,
                   dose_description = EXCLUDED.dose_description,
                   quantity = EXCLUDED.quantity,
                   refills_remaining = EXCLUDED.refills_remaining,
                   date_filled = EXCLUDED.date_filled,
                   pharmacy_name = EXCLUDED.pharmacy_name,
                   prescriber_name = EXCLUDED.prescriber_name,
                   ndc_code = EXCLUDED.ndc_code,
                   rx_status = EXCLUDED.rx_status,
                   last_fill_date = EXCLUDED.last_fill_date,
                   import_source = EXCLUDED.import_source,
                   walgreens_rx_id = EXCLUDED.walgreens_rx_id,
                   directions = EXCLUDED.directions
               WHERE prescriptions.import_source = 'walgreens'""",
            (
                rx_number, rx["medication_name"], rx["dose_mg"],
                rx.get("dose_description", ""), rx["quantity"],
                rx.get("refills_remaining", 0), rx["date_filled"],
                None,  # estimated_run_out_date
                rx.get("pharmacy_name", "Walgreens"),
                "",  # notes
                None,  # daily_dose_count
                rx.get("prescriber_name", ""), rx.get("ndc_code", ""),
                rx.get("rx_status", ""), rx.get("date_filled"),
                rx.get("walgreens_rx_id"), rx.get("directions", ""),
            ),
        )
        upserted += cur.rowcount

    conn.commit()
    return upserted


# ---------------------------------------------------------------------------
# Sync-log helper
# ---------------------------------------------------------------------------


def log_sync(conn, status, count):
    """Write an entry to sync_log and update walgreens_last_status setting."""
    now = datetime.now(timezone.utc).isoformat()
    if status == "success":
        set_setting(conn, "walgreens_last_sync", now)
    set_setting(
        conn, "walgreens_last_status",
        f"{status}: {count} prescriptions upserted" if status == "success" else status,
    )

    cur = conn.cursor()
    cur.execute(
        "INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id) "
        "VALUES (%s, %s, %s::jsonb, %s)",
        (
            "walgreens",
            "walgreens_web",
            f'{{"status": "{status}", "upserted": {count}}}',
            None,
        ),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sync Walgreens prescription data")
    parser.add_argument(
        "--check-schedule",
        action="store_true",
        help="Only run if the current hour matches walgreens_sync_time setting",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    conn = get_db()

    # --- Schedule gate -------------------------------------------------------
    if args.check_schedule:
        sync_time = get_setting(conn, "walgreens_sync_time")
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
    username = get_setting(conn, "walgreens_username")
    encrypted_pw = get_setting(conn, "walgreens_password")
    secret_key = os.environ.get("SECRET_KEY", "")
    if not secret_key:
        logger.error("SECRET_KEY env var is not set — cannot decrypt credentials")
        conn.close()
        return 3

    if not username or not encrypted_pw:
        logger.error("Walgreens credentials not configured in settings table")
        log_sync(conn, "no_credentials", 0)
        conn.close()
        return 3

    try:
        password = decrypt_value(encrypted_pw, secret_key)
    except Exception:
        logger.exception("Failed to decrypt Walgreens password")
        log_sync(conn, "decrypt_error", 0)
        conn.close()
        return 3

    # Security question answer (also encrypted)
    encrypted_answer = get_setting(conn, "walgreens_security_answer")
    security_answer = ""
    if encrypted_answer:
        try:
            security_answer = decrypt_value(encrypted_answer, secret_key)
        except Exception:
            logger.warning("Failed to decrypt security answer — will skip 2FA")

    # --- Saved session -------------------------------------------------------
    encrypted_session = get_setting(conn, "walgreens_session")
    session_data = None
    if encrypted_session:
        try:
            session_data = decrypt_value(encrypted_session, secret_key)
        except Exception:
            logger.warning("Failed to decrypt saved session — will do full login")

    # --- Determine date range ------------------------------------------------
    last_sync = get_setting(conn, "walgreens_last_sync")
    today = datetime.now(timezone.utc).date()
    if last_sync:
        # Look back 90 days on subsequent syncs
        start = (today - timedelta(days=90)).strftime("%m/%d/%Y")
    else:
        # First sync: go back 2 years (max Walgreens allows)
        start = (today - timedelta(days=730)).strftime("%m/%d/%Y")
    end = today.strftime("%m/%d/%Y")

    # --- Fetch from Walgreens ------------------------------------------------
    try:
        client = WalgreensClient(
            username=username,
            password=password,
            security_answer=security_answer,
        )
        prescriptions = client.fetch_prescriptions(
            session_data=session_data,
            start_date=start,
            end_date=end,
        )

        # Save session cookies for next run
        from crypto import encrypt_value
        new_session = client.save_session()
        encrypted = encrypt_value(new_session, secret_key)
        set_setting(conn, "walgreens_session", encrypted)

    except WalgreensAuthError as exc:
        logger.error("Walgreens authentication failed: %s", exc)
        log_sync(conn, "auth_error", 0)
        conn.close()
        return 1
    except WalgreensAPIError as exc:
        logger.error("Walgreens API error: %s", exc)
        log_sync(conn, "api_error", 0)
        conn.close()
        return 2

    # --- Upsert into DB ------------------------------------------------------
    count = upsert_prescriptions(conn, prescriptions)
    log_sync(conn, "success", count)

    logger.info(
        "Sync complete: %d prescriptions upserted (%d fetched)",
        count, len(prescriptions),
    )
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
