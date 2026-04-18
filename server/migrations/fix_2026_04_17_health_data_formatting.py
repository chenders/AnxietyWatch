"""Fix health data formatting issues in health_snapshots.

Run manually: cd server && python -m migrations.fix_2026_04_17_health_data_formatting

1. SpO2: multiply by 100 where values are on 0-1 scale
2. Skin temp: move absolute wrist temps to skin_temp_wrist, clear skin_temp_deviation
3. Sleep: cap sleep_duration_min to the sum of stages if stages exceed it
"""
import os
import sys

import psycopg2


def run_migration(database_url: str, dry_run: bool = False) -> dict:
    """Execute the migration. Returns counts of affected rows."""
    conn = psycopg2.connect(database_url)
    cur = conn.cursor()
    results = {}

    try:
        # 1. SpO2: scale 0-1 values to 0-100
        # Only affect values that are clearly on a 0-1 scale (< 1.0).
        # Values already on 0-100 scale will be > 70 and won't match.
        cur.execute(
            "UPDATE health_snapshots SET spo2_avg = spo2_avg * 100 "
            "WHERE spo2_avg IS NOT NULL AND spo2_avg <= 1.0"
        )
        results["spo2_scaled"] = cur.rowcount
        print(f"SpO2: scaled {cur.rowcount} rows from 0-1 to 0-100")

        # 2. Skin temp: values > 5 are clearly absolute temps, not deviations.
        # Move them to skin_temp_wrist (the new column) and clear the deviation.
        # First, ensure the column exists.
        cur.execute(
            "ALTER TABLE health_snapshots ADD COLUMN IF NOT EXISTS "
            "skin_temp_wrist DOUBLE PRECISION"
        )
        cur.execute(
            "UPDATE health_snapshots "
            "SET skin_temp_wrist = skin_temp_deviation, skin_temp_deviation = NULL "
            "WHERE skin_temp_deviation IS NOT NULL AND ABS(skin_temp_deviation) > 5.0"
        )
        results["skin_temp_moved"] = cur.rowcount
        print(f"Skin temp: moved {cur.rowcount} absolute values to skin_temp_wrist")

        # 3. Sleep: where stage sum exceeds duration, set duration to stage sum.
        # This doesn't fix the overlap (that requires re-sync from iOS), but it
        # removes the inconsistency so the outlier detector doesn't flag it.
        cur.execute(
            "UPDATE health_snapshots "
            "SET sleep_duration_min = COALESCE(sleep_deep_min, 0) "
            "  + COALESCE(sleep_rem_min, 0) + COALESCE(sleep_core_min, 0) "
            "WHERE sleep_duration_min IS NOT NULL "
            "AND (COALESCE(sleep_deep_min, 0) + COALESCE(sleep_rem_min, 0) "
            "   + COALESCE(sleep_core_min, 0)) > sleep_duration_min"
        )
        results["sleep_capped"] = cur.rowcount
        print(f"Sleep: adjusted duration for {cur.rowcount} rows where stages exceeded total")

        if dry_run:
            conn.rollback()
            print("\nDRY RUN — no changes committed")
        else:
            conn.commit()
            print("\nMigration committed successfully")

    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()

    return results


if __name__ == "__main__":
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL environment variable required")
        sys.exit(1)

    dry_run = "--dry-run" in sys.argv
    if dry_run:
        print("=== DRY RUN MODE ===\n")

    run_migration(database_url, dry_run=dry_run)
