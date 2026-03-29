"""CapRx claims sync — fetches pharmacy claims and upserts into PostgreSQL.

Can be run as a standalone CLI script or called from the admin UI.
Reads credentials from the settings table (encrypted) or env vars.

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
from caprx_client import (
    CapRxClient,
    CapRxAuthError,
    CapRxAPIError,
    normalize_claim,
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


# ---------------------------------------------------------------------------
# Core upsert logic
# ---------------------------------------------------------------------------


def upsert_prescriptions(conn, prescriptions):
    """Insert or update prescriptions from CapRx claims.

    - Rows with import_source = 'manual' are never overwritten.
    - Rows with import_source = 'caprx' are updated in place.
    - New rx_numbers are inserted with import_source = 'caprx'.

    Returns the number of rows inserted or updated.
    """
    if not prescriptions:
        return 0

    cur = conn.cursor()
    upserted = 0

    for rx in prescriptions:
        rx_number = rx["rx_number"]

        # Compute estimated run-out date from days_supply
        estimated_run_out = None
        if rx.get("days_supply") and rx.get("days_supply") > 0:
            estimated_run_out = rx["date_filled"] + timedelta(days=rx["days_supply"])

        cur.execute(
            """INSERT INTO prescriptions
                   (rx_number, medication_name, dose_mg, dose_description,
                    quantity, date_filled, estimated_run_out_date,
                    pharmacy_name, ndc_code, last_fill_date,
                    import_source)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'caprx')
               ON CONFLICT (rx_number) DO UPDATE SET
                   medication_name = EXCLUDED.medication_name,
                   dose_mg = EXCLUDED.dose_mg,
                   dose_description = EXCLUDED.dose_description,
                   quantity = EXCLUDED.quantity,
                   date_filled = EXCLUDED.date_filled,
                   estimated_run_out_date = EXCLUDED.estimated_run_out_date,
                   pharmacy_name = EXCLUDED.pharmacy_name,
                   ndc_code = EXCLUDED.ndc_code,
                   last_fill_date = EXCLUDED.last_fill_date,
                   import_source = EXCLUDED.import_source
               WHERE prescriptions.import_source != 'manual'""",
            (
                rx_number,
                rx["medication_name"],
                rx["dose_mg"],
                rx.get("dose_description", ""),
                rx["quantity"],
                rx["date_filled"],
                estimated_run_out,
                rx.get("pharmacy_name", ""),
                rx.get("ndc_code", ""),
                rx["date_filled"],  # last_fill_date = date_filled
            ),
        )
        upserted += cur.rowcount

    conn.commit()
    return upserted


# ---------------------------------------------------------------------------
# Sync-log helper
# ---------------------------------------------------------------------------


def log_sync(conn, status, count):
    """Write a sync log entry and update status settings."""
    now = datetime.now(timezone.utc).isoformat()
    if status == "success":
        set_setting(conn, "caprx_last_sync", now)
    set_setting(
        conn, "caprx_last_status",
        f"{status}: {count} prescriptions upserted" if status == "success" else status,
    )

    cur = conn.cursor()
    cur.execute(
        "INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id) "
        "VALUES (%s, %s, %s::jsonb, %s)",
        (
            "caprx",
            "caprx_api",
            f'{{"status": "{status}", "upserted": {count}}}',
            None,
        ),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Main sync function
# ---------------------------------------------------------------------------


def run_sync(conn=None, email=None, password=None):
    """Run a full CapRx claims sync.

    Returns (status, count) tuple.
    """
    close_conn = False
    if conn is None:
        conn = get_db()
        close_conn = True

    try:
        # Get credentials
        if not email:
            enc_email = get_setting(conn, "caprx_username")
            enc_password = get_setting(conn, "caprx_password")
            if enc_email and enc_password:
                email = decrypt_value(enc_email)
                password = decrypt_value(enc_password)
            else:
                # Fall back to env vars
                email = os.environ.get("CAPRX_USERNAME", "").strip("'")
                password = os.environ.get("CAPRX_PASSWORD", "").strip("'")

        if not email or not password:
            log_sync(conn, "error: no credentials configured", 0)
            return ("error", 0)

        # Authenticate
        client = CapRxClient(email, password)
        try:
            client.authenticate()
        except CapRxAuthError as e:
            logger.error("CapRx auth failed: %s", e)
            log_sync(conn, f"auth_error: {e}", 0)
            return ("auth_error", 0)

        # Fetch claims
        try:
            raw_claims = client.fetch_all_claims()
        except (CapRxAuthError, CapRxAPIError) as e:
            logger.error("CapRx fetch failed: %s", e)
            log_sync(conn, f"api_error: {e}", 0)
            return ("api_error", 0)

        # Normalize and upsert
        prescriptions = []
        for claim in raw_claims:
            normalized = normalize_claim(claim)
            if normalized:
                prescriptions.append(normalized)

        logger.info("CapRx: %d claims normalized from %d raw", len(prescriptions), len(raw_claims))
        count = upsert_prescriptions(conn, prescriptions)
        logger.info("CapRx: %d prescriptions upserted", count)
        log_sync(conn, "success", count)
        return ("success", count)

    except Exception as e:
        logger.exception("CapRx sync failed: %s", e)
        try:
            log_sync(conn, f"error: {e}", 0)
        except Exception:
            pass
        return ("error", 0)

    finally:
        if close_conn:
            conn.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Sync CapRx claims to PostgreSQL")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    status, count = run_sync()
    if status == "success":
        print(f"OK: {count} prescriptions upserted")
        sys.exit(0)
    elif status == "auth_error":
        print("Authentication failed")
        sys.exit(1)
    elif status == "api_error":
        print("API error")
        sys.exit(2)
    else:
        print(f"Error: {status}")
        sys.exit(3)


if __name__ == "__main__":
    main()
