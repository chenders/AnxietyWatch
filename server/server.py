"""Anxiety Watch Sync Server — receives data from the iOS app and stores it in PostgreSQL."""

import hashlib
import json
import os
from datetime import date, datetime, timezone
from functools import wraps

import psycopg2
import psycopg2.extras
from flask import Flask, g, jsonify, request

from correlations import (
    compute_correlations, store_correlations, get_correlations,
    get_paired_day_count, correlations_are_stale, MINIMUM_PAIRED_DAYS,
)
from genius import search_songs, fetch_song_metadata, scrape_lyrics, fetch_lyrics_musixmatch

# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------


def create_app(test_config=None):
    app = Flask(__name__)
    app.config["SESSION_COOKIE_SAMESITE"] = "Strict"

    if test_config:
        app.config.update(test_config)

    # Require SECRET_KEY from the environment for all non-testing runs.
    # Tests may rely on the env var set in CI, or fall back to a test-only default.
    secret_key = os.environ.get("SECRET_KEY")
    if secret_key:
        app.config["SECRET_KEY"] = secret_key
    elif app.config.get("TESTING"):
        app.config["SECRET_KEY"] = "test-secret-key"
    else:
        raise RuntimeError("SECRET_KEY environment variable is required")

    # Register admin blueprint
    from admin import admin_bp
    app.register_blueprint(admin_bp)

    # ---------------------------------------------------------------------------
    # Database helpers
    # ---------------------------------------------------------------------------

    def get_db():
        if "db" not in g:
            dsn = app.config.get("DATABASE_URL") or os.environ.get("DATABASE_URL")
            if not dsn:
                raise RuntimeError("DATABASE_URL not configured")
            g.db = psycopg2.connect(dsn)
            g.db.autocommit = False
        return g.db

    @app.teardown_appcontext
    def close_db(exc):
        db = g.pop("db", None)
        if db is not None:
            if exc:
                db.rollback()
            db.close()

    def init_db():
        """Apply database migrations via Alembic."""
        from alembic.config import Config
        from alembic import command

        # Match get_db(): require an explicit DATABASE_URL so Alembic cannot
        # fall back to the default sqlalchemy.url from alembic.ini.
        dsn = app.config.get("DATABASE_URL") or os.environ.get("DATABASE_URL")
        if not dsn:
            raise RuntimeError("DATABASE_URL not configured")

        alembic_ini = os.path.join(os.path.dirname(__file__), "alembic.ini")
        alembic_cfg = Config(alembic_ini)
        alembic_cfg.set_main_option("sqlalchemy.url", dsn)
        command.upgrade(alembic_cfg, "head")

    @app.cli.command("init-db")
    def init_db_command():
        with app.app_context():
            init_db()
            print("Database initialized.")

    # Auto-initialize on first request
    with app.app_context():
        try:
            init_db()
        except Exception:
            pass  # DB may not be available yet during testing/building

    # Make get_db available to admin blueprint
    app.get_db = get_db

    # ---------------------------------------------------------------------------
    # Auth
    # ---------------------------------------------------------------------------

    def require_api_key(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            auth = request.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                return jsonify({"error": "Missing Authorization header"}), 401

            token = auth[7:]
            key_hash = hashlib.sha256(token.encode()).hexdigest()

            db = get_db()
            cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(
                "SELECT id, is_active FROM api_keys WHERE key_hash = %s",
                (key_hash,),
            )
            row = cur.fetchone()

            if not row or not row["is_active"]:
                return jsonify({"error": "Invalid or revoked API key"}), 401

            # Update usage stats
            cur.execute(
                "UPDATE api_keys SET last_used_at = NOW(), request_count = request_count + 1 WHERE id = %s",
                (row["id"],),
            )
            db.commit()

            g.api_key_id = row["id"]
            return f(*args, **kwargs)

        return decorated

    # ---------------------------------------------------------------------------
    # POST /api/sync
    # ---------------------------------------------------------------------------

    @app.route("/api/sync", methods=["POST"])
    @require_api_key
    def sync():
        data = request.get_json(silent=True)
        if not data:
            return jsonify({"error": "Invalid JSON payload"}), 400

        db = get_db()
        cur = db.cursor()
        counts = {}

        try:
            counts["anxiety_entries"] = _upsert_anxiety_entries(cur, data.get("anxietyEntries", []))
            counts["medication_definitions"] = _upsert_medication_definitions(
                cur, data.get("medicationDefinitions", []))
            counts["medication_doses"] = _upsert_medication_doses(cur, data.get("medicationDoses", []))
            counts["cpap_sessions"] = _upsert_cpap_sessions(cur, data.get("cpapSessions", []))
            counts["health_snapshots"] = _upsert_health_snapshots(cur, data.get("healthSnapshots", []))
            counts["barometric_readings"] = _upsert_barometric_readings(cur, data.get("barometricReadings", []))
            counts["pharmacies"] = _upsert_pharmacies(cur, data.get("pharmacies", []))
            counts["prescriptions"] = _upsert_prescriptions(cur, data.get("prescriptions", []))
            counts["pharmacy_call_logs"] = _upsert_pharmacy_call_logs(cur, data.get("pharmacyCallLogs", []))
            _upsert_demographics(cur, data.get("demographics"))
            counts["songs"] = _upsert_songs(cur, data.get("songs", []))
            counts["song_occurrences"] = _upsert_song_occurrences(cur, data.get("songOccurrences", []))

            # Log the sync
            cur.execute(
                """INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id)
                   VALUES (%s, %s, %s, %s)""",
                (
                    data.get("syncType", "unknown"),
                    data.get("deviceName"),
                    json.dumps(counts),
                    g.api_key_id,
                ),
            )

            db.commit()
        except Exception:
            db.rollback()
            app.logger.exception("Sync failed")
            return jsonify({"error": "Internal server error"}), 500

        # Include latest correlations in sync response
        correlation_data = {}
        try:
            cur2 = db.cursor()
            paired_days = get_paired_day_count(cur2)
            if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur2):
                corr_results = compute_correlations(cur2)
                store_correlations(cur2, corr_results)
                db.commit()
            correlation_data = {
                "correlations": get_correlations(cur2),
                "paired_days": paired_days,
                "minimum_required": MINIMUM_PAIRED_DAYS,
            }
        except Exception:
            app.logger.exception("Correlation computation failed (non-fatal)")

        return jsonify({"status": "ok", "counts": counts, **correlation_data})

    # ---------------------------------------------------------------------------
    # GET /api/correlations
    # ---------------------------------------------------------------------------

    @app.route("/api/correlations", methods=["GET"])
    @require_api_key
    def api_correlations():
        db = get_db()
        cur = db.cursor()

        paired_days = get_paired_day_count(cur)

        if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur):
            results = compute_correlations(cur)
            store_correlations(cur, results)
            db.commit()

        correlations = get_correlations(cur)
        return jsonify({
            "correlations": correlations,
            "paired_days": paired_days,
            "minimum_required": MINIMUM_PAIRED_DAYS,
        })

    # ---------------------------------------------------------------------------
    # Upsert helpers
    # ---------------------------------------------------------------------------

    def _upsert_anxiety_entries(cur, entries):
        for e in entries:
            cur.execute(
                """INSERT INTO anxiety_entries (timestamp, severity, notes, tags)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (timestamp) DO UPDATE SET
                       severity = EXCLUDED.severity,
                       notes = EXCLUDED.notes,
                       tags = EXCLUDED.tags""",
                (e["timestamp"], e["severity"], e.get("notes", ""), json.dumps(e.get("tags", []))),
            )
        return len(entries)

    def _upsert_medication_definitions(cur, defs):
        for d in defs:
            cur.execute(
                """INSERT INTO medication_definitions (name, default_dose_mg, category, is_active)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (name) DO UPDATE SET
                       default_dose_mg = EXCLUDED.default_dose_mg,
                       category = EXCLUDED.category,
                       is_active = EXCLUDED.is_active""",
                (d["name"], d["defaultDoseMg"], d.get("category", ""), d.get("isActive", True)),
            )
        return len(defs)

    def _upsert_medication_doses(cur, doses):
        for d in doses:
            cur.execute(
                """INSERT INTO medication_doses (timestamp, medication_name, dose_mg, notes)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (timestamp, medication_name) DO UPDATE SET
                       dose_mg = EXCLUDED.dose_mg,
                       notes = EXCLUDED.notes""",
                (d["timestamp"], d["medicationName"], d["doseMg"], d.get("notes")),
            )
        return len(doses)

    def _upsert_cpap_sessions(cur, sessions):
        for s in sessions:
            cur.execute(
                """INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, leak_rate_95th,
                       pressure_min, pressure_max, pressure_mean,
                       obstructive_events, central_events, hypopnea_events, import_source)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (date) DO UPDATE SET
                       ahi = EXCLUDED.ahi,
                       total_usage_minutes = EXCLUDED.total_usage_minutes,
                       leak_rate_95th = COALESCE(EXCLUDED.leak_rate_95th, cpap_sessions.leak_rate_95th),
                       pressure_min = EXCLUDED.pressure_min,
                       pressure_max = EXCLUDED.pressure_max,
                       pressure_mean = EXCLUDED.pressure_mean,
                       obstructive_events = EXCLUDED.obstructive_events,
                       central_events = EXCLUDED.central_events,
                       hypopnea_events = EXCLUDED.hypopnea_events,
                       import_source = EXCLUDED.import_source""",
                (
                    s["date"], s["ahi"], s["totalUsageMinutes"], s.get("leakRate95th"),
                    s["pressureMin"], s["pressureMax"], s["pressureMean"],
                    s.get("obstructiveEvents", 0), s.get("centralEvents", 0),
                    s.get("hypopneaEvents", 0), s.get("importSource", "sd_card"),
                ),
            )
        return len(sessions)

    def _upsert_health_snapshots(cur, snapshots):
        for s in snapshots:
            cur.execute(
                """INSERT INTO health_snapshots (
                       date, hrv_avg, hrv_min, resting_hr,
                       sleep_duration_min, sleep_deep_min, sleep_rem_min, sleep_core_min, sleep_awake_min,
                       skin_temp_deviation, skin_temp_wrist, respiratory_rate, spo2_avg,
                       steps, active_calories, exercise_minutes,
                       environmental_sound_avg, bp_systolic, bp_diastolic, blood_glucose_avg,
                       cpap_ahi, cpap_usage_minutes,
                       barometric_pressure_avg_kpa, barometric_pressure_change_kpa)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                           %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (date) DO UPDATE SET
                       hrv_avg = EXCLUDED.hrv_avg,
                       hrv_min = EXCLUDED.hrv_min,
                       resting_hr = EXCLUDED.resting_hr,
                       sleep_duration_min = EXCLUDED.sleep_duration_min,
                       sleep_deep_min = EXCLUDED.sleep_deep_min,
                       sleep_rem_min = EXCLUDED.sleep_rem_min,
                       sleep_core_min = EXCLUDED.sleep_core_min,
                       sleep_awake_min = EXCLUDED.sleep_awake_min,
                       skin_temp_deviation = EXCLUDED.skin_temp_deviation,
                       skin_temp_wrist = EXCLUDED.skin_temp_wrist,
                       respiratory_rate = EXCLUDED.respiratory_rate,
                       spo2_avg = EXCLUDED.spo2_avg,
                       steps = EXCLUDED.steps,
                       active_calories = EXCLUDED.active_calories,
                       exercise_minutes = EXCLUDED.exercise_minutes,
                       environmental_sound_avg = EXCLUDED.environmental_sound_avg,
                       bp_systolic = EXCLUDED.bp_systolic,
                       bp_diastolic = EXCLUDED.bp_diastolic,
                       blood_glucose_avg = EXCLUDED.blood_glucose_avg,
                       cpap_ahi = EXCLUDED.cpap_ahi,
                       cpap_usage_minutes = EXCLUDED.cpap_usage_minutes,
                       barometric_pressure_avg_kpa = EXCLUDED.barometric_pressure_avg_kpa,
                       barometric_pressure_change_kpa = EXCLUDED.barometric_pressure_change_kpa""",
                (
                    s["date"], s.get("hrvAvg"), s.get("hrvMin"), s.get("restingHR"),
                    s.get("sleepDurationMin"), s.get("sleepDeepMin"), s.get("sleepREMMin"),
                    s.get("sleepCoreMin"), s.get("sleepAwakeMin"),
                    s.get("skinTempDeviation"), s.get("skinTempWrist"), s.get("respiratoryRate"), s.get("spo2Avg"),
                    s.get("steps"), s.get("activeCalories"), s.get("exerciseMinutes"),
                    s.get("environmentalSoundAvg"), s.get("bpSystolic"), s.get("bpDiastolic"),
                    s.get("bloodGlucoseAvg"),
                    s.get("cpapAHI"), s.get("cpapUsageMinutes"),
                    s.get("barometricPressureAvgKPa"), s.get("barometricPressureChangeKPa"),
                ),
            )
        return len(snapshots)

    def _upsert_barometric_readings(cur, readings):
        for r in readings:
            cur.execute(
                """INSERT INTO barometric_readings (timestamp, pressure_kpa, relative_altitude_m)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (timestamp) DO UPDATE SET
                       pressure_kpa = EXCLUDED.pressure_kpa,
                       relative_altitude_m = EXCLUDED.relative_altitude_m""",
                (r["timestamp"], r["pressureKPa"], r["relativeAltitudeM"]),
            )
        return len(readings)

    def _upsert_pharmacies(cur, pharmacies):
        for p in pharmacies:
            cur.execute(
                """INSERT INTO pharmacies (name, address, phone_number, latitude, longitude, notes, is_active)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (name) DO UPDATE SET
                       address = EXCLUDED.address,
                       phone_number = EXCLUDED.phone_number,
                       latitude = EXCLUDED.latitude,
                       longitude = EXCLUDED.longitude,
                       notes = EXCLUDED.notes,
                       is_active = EXCLUDED.is_active""",
                (p["name"], p.get("address", ""), p.get("phoneNumber", ""),
                 p.get("latitude"), p.get("longitude"),
                 p.get("notes", ""), p.get("isActive", True)),
            )
        return len(pharmacies)

    def _upsert_prescriptions(cur, prescriptions):
        for rx in prescriptions:
            cur.execute(
                """INSERT INTO prescriptions (rx_number, medication_name, dose_mg, dose_description,
                       quantity, refills_remaining, date_filled, estimated_run_out_date,
                       pharmacy_name, notes, daily_dose_count,
                       prescriber_name, ndc_code, rx_status, last_fill_date,
                       import_source, walgreens_rx_id, directions)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                           %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (rx_number) DO UPDATE SET
                       medication_name = EXCLUDED.medication_name,
                       dose_mg = EXCLUDED.dose_mg,
                       dose_description = EXCLUDED.dose_description,
                       quantity = EXCLUDED.quantity,
                       refills_remaining = EXCLUDED.refills_remaining,
                       date_filled = EXCLUDED.date_filled,
                       estimated_run_out_date = EXCLUDED.estimated_run_out_date,
                       pharmacy_name = EXCLUDED.pharmacy_name,
                       notes = EXCLUDED.notes,
                       daily_dose_count = EXCLUDED.daily_dose_count,
                       prescriber_name = EXCLUDED.prescriber_name,
                       ndc_code = EXCLUDED.ndc_code,
                       rx_status = EXCLUDED.rx_status,
                       last_fill_date = EXCLUDED.last_fill_date,
                       import_source = EXCLUDED.import_source,
                       walgreens_rx_id = EXCLUDED.walgreens_rx_id,
                       directions = EXCLUDED.directions""",
                (rx["rxNumber"], rx["medicationName"], rx["doseMg"],
                 rx.get("doseDescription", ""), rx["quantity"],
                 rx.get("refillsRemaining", 0), rx["dateFilled"],
                 rx.get("estimatedRunOutDate"), rx.get("pharmacyName", ""),
                 rx.get("notes", ""), rx.get("dailyDoseCount"),
                 rx.get("prescriberName", ""), rx.get("ndcCode", ""),
                 rx.get("rxStatus", ""), rx.get("lastFillDate"),
                 rx.get("importSource", "manual"), rx.get("walgreensRxId"),
                 rx.get("directions", "")),
            )
        return len(prescriptions)

    def _upsert_pharmacy_call_logs(cur, logs):
        for c in logs:
            cur.execute(
                """INSERT INTO pharmacy_call_logs (timestamp, pharmacy_name, direction, notes, duration_seconds)
                   VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (timestamp, pharmacy_name) DO UPDATE SET
                       direction = EXCLUDED.direction,
                       notes = EXCLUDED.notes,
                       duration_seconds = EXCLUDED.duration_seconds""",
                (c["timestamp"], c["pharmacyName"], c.get("direction", "attempted"),
                 c.get("notes", ""), c.get("durationSeconds")),
            )
        return len(logs)

    def _upsert_demographics(cur, demographics):
        """Upsert HealthKit demographics into patient_profile.

        Only sets date_of_birth and gender if the row doesn't exist yet
        or those fields are currently NULL — never overwrites manual entries.
        """
        if not demographics:
            return

        dob = demographics.get("dateOfBirth")
        sex = demographics.get("biologicalSex")
        if not dob and not sex:
            return

        # Validate date format before passing to Postgres
        if dob:
            try:
                date.fromisoformat(dob)
            except (ValueError, TypeError):
                dob = None

        # Normalize biologicalSex to canonical gender values
        if sex:
            valid_genders = {"male", "female", "non_binary", "other", "prefer_not_to_say"}
            sex = sex.lower().replace("-", "_").replace(" ", "_")
            if sex not in valid_genders:
                sex = None

        # After validation, both may have been cleared — nothing to upsert
        if not dob and not sex:
            return

        cur.execute("SELECT id, date_of_birth, gender FROM patient_profile LIMIT 1")
        existing = cur.fetchone()

        if existing:
            updates = []
            values = []
            if dob and existing[1] is None:  # date_of_birth is NULL
                updates.append("date_of_birth = %s")
                values.append(dob)
            if sex and existing[2] is None:  # gender is NULL
                updates.append("gender = %s")
                values.append(sex)
            if updates:
                updates.append("updated_at = NOW()")
                values.append(existing[0])
                cur.execute(
                    f"UPDATE patient_profile SET {', '.join(updates)} WHERE id = %s",
                    values,
                )
        else:
            cur.execute(
                "INSERT INTO patient_profile (date_of_birth, gender) VALUES (%s, %s)",
                (dob, sex),
            )

    def _upsert_songs(cur, songs):
        for s in songs:
            genius_id = s.get("geniusId")
            if genius_id:
                cur.execute(
                    """INSERT INTO songs (genius_id, title, artist, album, album_art_url,
                                          genius_url, lyrics, lyrics_source, updated_at)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, COALESCE(%s::timestamptz, NOW()))
                       ON CONFLICT (genius_id) DO UPDATE SET
                           title = EXCLUDED.title,
                           artist = EXCLUDED.artist,
                           album = COALESCE(EXCLUDED.album, songs.album),
                           album_art_url = COALESCE(EXCLUDED.album_art_url, songs.album_art_url),
                           genius_url = COALESCE(EXCLUDED.genius_url, songs.genius_url),
                           lyrics = COALESCE(EXCLUDED.lyrics, songs.lyrics),
                           lyrics_source = COALESCE(EXCLUDED.lyrics_source, songs.lyrics_source),
                           updated_at = GREATEST(EXCLUDED.updated_at, songs.updated_at)
                       WHERE EXCLUDED.updated_at >= songs.updated_at""",
                    (genius_id, s["title"], s["artist"], s.get("album"),
                     s.get("albumArtUrl"), s.get("geniusUrl"),
                     s.get("lyrics"), s.get("lyricsSource"), s.get("updatedAt")),
                )
            else:
                # Manual song without genius_id — upsert by normalized title+artist
                cur.execute(
                    """INSERT INTO songs (title, artist, album, lyrics, lyrics_source, updated_at)
                       VALUES (%s, %s, %s, %s, %s, COALESCE(%s::timestamptz, NOW()))
                       ON CONFLICT (lower(btrim(title)), lower(btrim(artist)))
                           WHERE genius_id IS NULL
                       DO UPDATE SET
                           album = COALESCE(EXCLUDED.album, songs.album),
                           lyrics = COALESCE(EXCLUDED.lyrics, songs.lyrics),
                           lyrics_source = COALESCE(EXCLUDED.lyrics_source, songs.lyrics_source),
                           updated_at = GREATEST(EXCLUDED.updated_at, songs.updated_at)
                       WHERE EXCLUDED.updated_at >= songs.updated_at""",
                    (s["title"], s["artist"], s.get("album"),
                     s.get("lyrics"), s.get("lyricsSource"), s.get("updatedAt")),
                )
        return len(songs)

    def _upsert_song_occurrences(cur, occurrences):
        for o in occurrences:
            # Resolve song_id from genius_id or server_id
            song_id = None
            genius_id = o.get("songGeniusId")
            if genius_id:
                cur.execute("SELECT id FROM songs WHERE genius_id = %s", (genius_id,))
                row = cur.fetchone()
                if row:
                    song_id = row[0] if isinstance(row, tuple) else row["id"]
            if not song_id:
                server_id = o.get("songServerId")
                if server_id:
                    song_id = server_id

            if not song_id:
                continue  # Can't link occurrence without a song

            cur.execute(
                """INSERT INTO song_occurrences (song_id, timestamp, source, anxiety_entry_id, notes)
                   VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (song_id, timestamp, source) DO NOTHING""",
                (song_id, o["timestamp"], o.get("source") or "standalone",
                 o.get("anxietyEntryTimestamp"), o.get("notes")),
            )
        return len(occurrences)

    # ---------------------------------------------------------------------------
    # GET /api/data
    # ---------------------------------------------------------------------------

    @app.route("/api/data", methods=["GET"])
    @require_api_key
    def get_all_data():
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        since = request.args.get("since")

        result = {}
        for entity in ENTITY_QUERIES:
            result[entity] = _query_entity(cur, entity, since)

        result["exportDate"] = datetime.now(timezone.utc).isoformat()
        return jsonify(result)

    @app.route("/api/data/<entity>", methods=["GET"])
    @require_api_key
    def get_entity_data(entity):
        if entity not in ENTITY_QUERIES:
            return jsonify({"error": f"Unknown entity: {entity}"}), 404

        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        since = request.args.get("since")

        rows = _query_entity(cur, entity, since)
        return jsonify({entity: rows, "exportDate": datetime.now(timezone.utc).isoformat()})

    # Entity query config: {name: (table, time_column, order_column)}
    ENTITY_QUERIES = {
        "anxietyEntries": ("anxiety_entries", "timestamp", "timestamp"),
        "medicationDefinitions": ("medication_definitions", None, "name"),
        "medicationDoses": ("medication_doses", "timestamp", "timestamp"),
        "cpapSessions": ("cpap_sessions", "date", "date"),
        "healthSnapshots": ("health_snapshots", "date", "date"),
        "barometricReadings": ("barometric_readings", "timestamp", "timestamp"),
        "pharmacies": ("pharmacies", None, "name"),
        "prescriptions": ("prescriptions", None, "date_filled"),
        "pharmacyCallLogs": ("pharmacy_call_logs", "timestamp", "timestamp"),
    }

    def _query_entity(cur, entity, since=None):
        table, time_col, order_col = ENTITY_QUERIES[entity]
        if since and time_col:
            cur.execute(
                f"SELECT * FROM {table} WHERE {time_col} >= %s ORDER BY {order_col} DESC",
                (since,),
            )
        else:
            cur.execute(f"SELECT * FROM {table} ORDER BY {order_col} DESC")
        rows = cur.fetchall()
        # Serialize dates/datetimes to ISO strings
        return [_serialize_row(r) for r in rows]

    # ---------------------------------------------------------------------------
    # Song endpoints
    # ---------------------------------------------------------------------------

    @app.route("/api/songs/search", methods=["GET"])
    @require_api_key
    def api_songs_search():
        query = request.args.get("q", "").strip()
        if not query:
            return jsonify({"error": "Missing query parameter 'q'"}), 400
        token = os.environ.get("GENIUS_API_TOKEN")
        results = search_songs(query, api_token=token)
        return jsonify({"results": results})

    @app.route("/api/songs", methods=["GET"])
    @require_api_key
    def api_songs_list():
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("""
            SELECT s.id, s.genius_id, s.title, s.artist, s.album,
                   s.album_art_url, s.genius_url, s.updated_at,
                   s.lyrics, s.lyrics_source,
                   s.lyrics IS NOT NULL AS has_lyrics,
                   COUNT(so.id) AS occurrence_count,
                   MAX(so.timestamp) AS last_occurrence
            FROM songs s
            LEFT JOIN song_occurrences so ON so.song_id = s.id
            GROUP BY s.id
            ORDER BY last_occurrence DESC NULLS LAST, s.title
        """)
        songs = [_serialize_row(row) for row in cur.fetchall()]
        return jsonify({"songs": songs})

    @app.route("/api/songs", methods=["POST"])
    @require_api_key
    def api_songs_create():
        data = request.get_json(silent=True) or {}
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        genius_id = data.get("genius_id")

        # If genius_id provided, check for existing
        if genius_id:
            cur.execute("SELECT * FROM songs WHERE genius_id = %s", (genius_id,))
            existing = cur.fetchone()
            if existing:
                db.commit()
                return jsonify(_serialize_row(existing)), 200

            # Fetch metadata and lyrics from Genius
            token = os.environ.get("GENIUS_API_TOKEN")
            meta = fetch_song_metadata(genius_id, api_token=token)
            if not meta:
                return jsonify({"error": "Could not fetch song metadata"}), 502

            lyrics = None
            lyrics_source = None
            if meta.get("genius_url"):
                lyrics = scrape_lyrics(meta["genius_url"])
                if lyrics:
                    lyrics_source = "genius"
            if not lyrics:
                lyrics = fetch_lyrics_musixmatch(meta["title"], meta["artist"])
                if lyrics:
                    lyrics_source = "musixmatch"

            cur.execute(
                """INSERT INTO songs (genius_id, title, artist, album, album_art_url, genius_url, lyrics, lyrics_source)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                   RETURNING *""",
                (genius_id, meta["title"], meta["artist"], meta.get("album"),
                 meta.get("album_art_url"), meta.get("genius_url"), lyrics, lyrics_source),
            )
        else:
            # Manual entry — title and artist required
            title = data.get("title", "").strip()
            artist = data.get("artist", "").strip()
            if not title or not artist:
                return jsonify({"error": "title and artist are required"}), 400
            # Check for existing manual song (normalized match)
            cur.execute(
                """SELECT * FROM songs
                   WHERE genius_id IS NULL
                     AND lower(btrim(title)) = lower(btrim(%s))
                     AND lower(btrim(artist)) = lower(btrim(%s))""",
                (title, artist),
            )
            existing = cur.fetchone()
            if existing:
                db.commit()
                return jsonify(_serialize_row(existing)), 200
            cur.execute(
                """INSERT INTO songs (title, artist, album, album_art_url)
                   VALUES (%s, %s, %s, %s)
                   RETURNING *""",
                (title, artist, data.get("album"), data.get("album_art_url")),
            )

        song = cur.fetchone()
        db.commit()
        return jsonify(_serialize_row(song)), 201

    @app.route("/api/songs/<int:song_id>", methods=["PUT"])
    @require_api_key
    def api_songs_update(song_id):
        data = request.get_json(silent=True) or {}
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # Build SET clause from allowed fields
        allowed = {"title", "artist", "album", "album_art_url", "genius_url", "lyrics", "lyrics_source"}
        updates = {k: v for k, v in data.items() if k in allowed}
        if not updates:
            return jsonify({"error": "No valid fields to update"}), 400

        set_parts = []
        values = []
        for k, v in updates.items():
            set_parts.append(f"{k} = %s")
            values.append(v)
        set_parts.append("updated_at = NOW()")
        values.append(song_id)

        cur.execute(
            f"UPDATE songs SET {', '.join(set_parts)} WHERE id = %s RETURNING *",
            values,
        )
        song = cur.fetchone()
        if not song:
            return jsonify({"error": "Song not found"}), 404
        db.commit()
        return jsonify(_serialize_row(song))

    @app.route("/api/songs/<int:song_id>/occurrences", methods=["POST"])
    @require_api_key
    def api_song_occurrence_create(song_id):
        data = request.get_json(silent=True) or {}
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        timestamp = data.get("timestamp")
        if not timestamp:
            return jsonify({"error": "timestamp is required"}), 400

        cur.execute("SELECT 1 FROM songs WHERE id = %s", (song_id,))
        if cur.fetchone() is None:
            return jsonify({"error": "song not found"}), 404

        cur.execute(
            """INSERT INTO song_occurrences (song_id, timestamp, source, anxiety_entry_id, notes)
               VALUES (%s, %s, %s, %s, %s)
               RETURNING *""",
            (song_id, timestamp, data.get("source") or "standalone", data.get("anxiety_entry_id"), data.get("notes")),
        )
        occurrence = cur.fetchone()
        db.commit()
        return jsonify(_serialize_row(occurrence)), 201

    def _serialize_row(row):
        result = {}
        for k, v in row.items():
            if isinstance(v, (datetime,)):
                result[k] = v.isoformat()
            elif hasattr(v, "isoformat"):  # date objects
                result[k] = v.isoformat()
            else:
                result[k] = v
        return result

    # ---------------------------------------------------------------------------
    # GET /api/status
    # ---------------------------------------------------------------------------

    @app.route("/api/status", methods=["GET"])
    @require_api_key
    def status():
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        counts = {}
        for entity, (table, _, _) in ENTITY_QUERIES.items():
            cur.execute(f"SELECT COUNT(*) AS count FROM {table}")
            counts[entity] = cur.fetchone()["count"]

        # Last sync
        cur.execute("SELECT received_at, sync_type, device_name FROM sync_log ORDER BY received_at DESC LIMIT 1")
        last_sync = cur.fetchone()
        if last_sync:
            last_sync = _serialize_row(last_sync)

        return jsonify({
            "status": "ok",
            "counts": counts,
            "lastSync": last_sync,
        })

    # ---------------------------------------------------------------------------
    # Health check (no auth)
    # ---------------------------------------------------------------------------

    @app.route("/health", methods=["GET"])
    def health():
        try:
            db = get_db()
            db.cursor().execute("SELECT 1")
            return jsonify({"status": "ok"})
        except Exception:
            return jsonify({"status": "error"}), 500

    return app


# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=8080, debug=True)
