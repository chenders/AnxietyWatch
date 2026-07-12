"""Anxiety Watch Sync Server — receives data from the iOS app and stores it in PostgreSQL."""

import hashlib
import json
import os
import re
import uuid
from datetime import date, datetime, timezone
from functools import wraps

import psycopg2
import psycopg2.extras
from psycopg2 import sql
from flask import Flask, g, jsonify, request
from markupsafe import Markup, escape

from correlations import (
    compute_correlations, store_correlations, get_correlations,
    get_paired_day_count, correlations_are_stale, MINIMUM_PAIRED_DAYS,
    compute_staleness_fingerprint, resolve_analysis_timezone,
)
from genius import search_songs, fetch_song_metadata, scrape_lyrics, fetch_lyrics_musixmatch

# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------


def create_app(test_config=None):
    app = Flask(__name__)
    app.config["SESSION_COOKIE_SAMESITE"] = "Strict"
    # Secure flag is opt-in via env because the reference deployment serves
    # plain HTTP on the LAN — enabling it unconditionally would silently make
    # the admin session cookie undeliverable and lock the maintainer out.
    # Run behind TLS and set SESSION_COOKIE_SECURE=1 (see docs/SERVER_SETUP.md).
    app.config["SESSION_COOKIE_SECURE"] = (
        os.environ.get("SESSION_COOKIE_SECURE", "").strip().lower() in ("1", "true", "yes")
    )

    if test_config:
        app.config.update(test_config)

    # Require SECRET_KEY from the environment for all non-testing runs.
    # Precedence: env var > test_config/app.config > test-only default.
    secret_key = os.environ.get("SECRET_KEY") or app.config.get("SECRET_KEY")
    if secret_key:
        app.config["SECRET_KEY"] = secret_key
    elif app.config.get("TESTING"):
        # Not a real credential; only reachable when TESTING is explicitly set
        # (see test_create_app_uses_test_default_when_testing and
        # test_create_app_raises_without_secret_key below). Prod (TESTING
        # unset/false) always raises instead of silently falling back.
        app.config["SECRET_KEY"] = "test-secret-key"  # nosec B105
    else:
        raise RuntimeError("SECRET_KEY environment variable is required")

    # Register admin blueprint
    from admin import admin_bp
    app.register_blueprint(admin_bp)

    # -----------------------------------------------------------------------
    # Jinja2 template filters for Claude API text formatting
    # -----------------------------------------------------------------------

    @app.template_filter("format_analysis")
    def format_analysis_filter(text):
        """Convert markdown bold and <cite> tags to HTML in analysis text.

        Escapes HTML first for safety, then applies formatting conversions.
        """
        if not text:
            return text
        s = str(escape(text))
        # Markdown bold: **text** → <strong>text</strong>
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
        # <cite index="...">text</cite> (already escaped to &lt;cite ...&gt;)
        s = re.sub(
            r'&lt;cite.*?&gt;(.+?)&lt;/cite&gt;',
            r'<q>\1</q>',
            s,
        )
        # `s` was HTML-escaped via markupsafe.escape() above before any regex
        # substitution; the substitutions only ever emit literal <strong>/<q>
        # tags around already-escaped text, so no unescaped request-derived
        # content can reach this Markup() wrapper (see
        # TestFormatAnalysisFilter.test_html_escaped in tests/test_server.py).
        return Markup(s)  # nosec B704

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

    # Auto-initialize at app creation (startup), before the app serves any
    # request. We deliberately keep booting on failure (a transient lock or a partially
    # applied migration shouldn't take the whole service down), but the danger
    # is booting silently against a stale schema. Log the full traceback at
    # ERROR so a failed migration is loud and diagnosable, not a one-line
    # type-name at WARNING that hides why later /api/sync calls 500.
    with app.app_context():
        try:
            init_db()
        except Exception:
            app.logger.exception(
                "Database migration failed on startup; continuing against a "
                "possibly stale schema"
            )

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
            # Schema version flag — distinguishes "modern client sent
            # explicit nil" from "older client doesn't know about a field"
            # for fields that Swift Codable omits when nil. v >= 2 means the
            # client knows about the seven overnight clinical stats columns.
            try:
                schema_version = int(data.get("syncSchemaVersion", 1) or 1)
            except (TypeError, ValueError):
                schema_version = 1

            counts["anxiety_entries"] = _upsert_anxiety_entries(cur, data.get("anxietyEntries", []))
            counts["medication_definitions"] = _upsert_medication_definitions(
                cur, data.get("medicationDefinitions", []))
            counts["medication_doses"] = _upsert_medication_doses(cur, data.get("medicationDoses", []))
            counts["cpap_sessions"] = _upsert_cpap_sessions(cur, data.get("cpapSessions", []))
            counts["health_snapshots"] = _upsert_health_snapshots(
                cur, data.get("healthSnapshots", []), schema_version=schema_version,
            )
            counts["quantity_health_samples"] = _upsert_quantity_health_samples(
                cur, data.get("quantitySamples", []),
            )
            counts["sleep_stage_events"] = _upsert_sleep_stage_events(
                cur, data.get("sleepStageEvents", []),
            )
            # Polar H10 (and future BLE-strap) recording sessions + per-
            # minute HRV. Sessions before readings so the FK is satisfied
            # even when both are uploaded in the same /api/sync call.
            counts["sensor_sessions"] = _upsert_sensor_sessions(
                cur, data.get("sensorSessions", []),
            )
            counts["hrv_readings"] = _upsert_hrv_readings(
                cur, data.get("hrvReadings", []),
            )
            # Watch accelerometer pipeline (syncSchemaVersion 6): 10-second
            # FFT spectral windows + per-minute derived breathing rate.
            counts["accel_spectrograms"] = _upsert_accel_spectrograms(
                cur, data.get("accelSpectrograms", []),
            )
            counts["derived_breathing_rates"] = _upsert_derived_breathing_rates(
                cur, data.get("derivedBreathingRates", []),
            )
            counts["barometric_readings"] = _upsert_barometric_readings(cur, data.get("barometricReadings", []))
            counts["pharmacies"] = _upsert_pharmacies(cur, data.get("pharmacies", []))
            counts["prescriptions"] = _upsert_prescriptions(cur, data.get("prescriptions", []))
            counts["pharmacy_call_logs"] = _upsert_pharmacy_call_logs(cur, data.get("pharmacyCallLogs", []))
            _upsert_demographics(cur, data.get("demographics"))
            counts["songs"] = _upsert_songs(cur, data.get("songs", []))
            occ_upserted, occ_skipped = _upsert_song_occurrences(cur, data.get("songOccurrences", []))
            counts["song_occurrences"] = occ_upserted
            if occ_skipped:
                # Additive key — the iOS client ignores unknown count keys.
                # Also lands in sync_log.record_counts via the insert below.
                counts["song_occurrences_skipped"] = occ_skipped

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
            tz_name = resolve_analysis_timezone(cur2)
            paired_days = get_paired_day_count(cur2, tz_name)
            if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur2):
                # Capture the fingerprint BEFORE computing so a row inserted
                # mid-computation still reads as stale on the next check.
                fingerprint = compute_staleness_fingerprint(cur2)
                corr_results = compute_correlations(cur2, tz_name)
                store_correlations(cur2, corr_results, fingerprint)
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
    # POST /api/sensor_sessions/<id>/rr_archive
    # ---------------------------------------------------------------------------

    # Upload the gzipped raw RR-interval archive for a completed
    # SensorSession. Kept separate from /api/sync because the payload is
    # binary (the iOS side compresses the per-session .rr file at upload
    # time with Data.compressed(using: .zlib)); ~80–120 KB / overnight
    # session. The session row must already exist (sync first, archive
    # second) so we have a row to attach to.
    MAX_RR_ARCHIVE_BYTES = 5 * 1024 * 1024  # 5 MB cap; overnight gzip ~120 KB

    @app.route("/api/sensor_sessions/<session_id>/rr_archive", methods=["POST"])
    @require_api_key
    def upload_rr_archive(session_id):
        try:
            uuid.UUID(session_id)
        except (TypeError, ValueError):
            return jsonify({"error": "Invalid session id"}), 400

        # Resource existence comes before payload validation so that
        # debugging is unambiguous: a POST to an unknown session_id always
        # returns 404, regardless of body shape. Cheap SELECT 1 — this
        # endpoint is called once per overnight session, not in a hot path.
        db = get_db()
        cur = db.cursor()
        cur.execute("SELECT 1 FROM sensor_sessions WHERE id = %s", (session_id,))
        if cur.fetchone() is None:
            return jsonify({"error": "Unknown session id"}), 404

        # Reject oversize payloads *before* buffering the full body. First
        # the cheap Content-Length check (catches honest clients), then a
        # bounded-chunk read from request.stream so chunked-transfer
        # uploads (no Content-Length) can't bypass the cap by streaming
        # arbitrarily large bodies.
        if request.content_length is not None and request.content_length > MAX_RR_ARCHIVE_BYTES:
            return jsonify({"error": "Archive too large"}), 413

        chunks = []
        total = 0
        while True:
            chunk = request.stream.read(64 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RR_ARCHIVE_BYTES:
                return jsonify({"error": "Archive too large"}), 413
            chunks.append(chunk)
        if total == 0:
            return jsonify({"error": "Empty archive payload"}), 400
        data = b"".join(chunks)

        try:
            cur.execute(
                "UPDATE sensor_sessions SET rr_archive = %s WHERE id = %s",
                (psycopg2.Binary(data), session_id),
            )
            db.commit()
        except Exception:
            db.rollback()
            app.logger.exception("rr_archive upload failed")
            return jsonify({"error": "Internal server error"}), 500
        return jsonify({"status": "ok", "bytes": len(data)})

    # ---------------------------------------------------------------------------
    # GET /api/correlations
    # ---------------------------------------------------------------------------

    @app.route("/api/correlations", methods=["GET"])
    @require_api_key
    def api_correlations():
        db = get_db()
        cur = db.cursor()

        tz_name = resolve_analysis_timezone(cur)
        paired_days = get_paired_day_count(cur, tz_name)

        if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur):
            # Capture the fingerprint BEFORE computing so a row inserted
            # mid-computation still reads as stale on the next check.
            fingerprint = compute_staleness_fingerprint(cur)
            results = compute_correlations(cur, tz_name)
            store_correlations(cur, results, fingerprint)
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
                       obstructive_events, central_events, hypopnea_events, import_source,
                       rdi_events, rera_events, spo2_avg, spo2_min, pulse_avg,
                       pressure_95th, leak_avg, leak_max)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                           %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (date) DO UPDATE SET
                       ahi = COALESCE(EXCLUDED.ahi, cpap_sessions.ahi),
                       total_usage_minutes = EXCLUDED.total_usage_minutes,
                       leak_rate_95th = COALESCE(EXCLUDED.leak_rate_95th, cpap_sessions.leak_rate_95th),
                       pressure_min = EXCLUDED.pressure_min,
                       pressure_max = EXCLUDED.pressure_max,
                       pressure_mean = EXCLUDED.pressure_mean,
                       obstructive_events = EXCLUDED.obstructive_events,
                       central_events = EXCLUDED.central_events,
                       hypopnea_events = EXCLUDED.hypopnea_events,
                       import_source = EXCLUDED.import_source,
                       rdi_events = COALESCE(EXCLUDED.rdi_events, cpap_sessions.rdi_events),
                       rera_events = COALESCE(EXCLUDED.rera_events, cpap_sessions.rera_events),
                       spo2_avg = COALESCE(EXCLUDED.spo2_avg, cpap_sessions.spo2_avg),
                       spo2_min = COALESCE(EXCLUDED.spo2_min, cpap_sessions.spo2_min),
                       pulse_avg = COALESCE(EXCLUDED.pulse_avg, cpap_sessions.pulse_avg),
                       pressure_95th = COALESCE(EXCLUDED.pressure_95th, cpap_sessions.pressure_95th),
                       leak_avg = COALESCE(EXCLUDED.leak_avg, cpap_sessions.leak_avg),
                       leak_max = COALESCE(EXCLUDED.leak_max, cpap_sessions.leak_max)""",
                (
                    # ahi is nullable (migration 0007): NULL means "not
                    # measured" (EDF-only import). COALESCE above ensures a
                    # null from the client never clobbers a measured value.
                    s["date"], s.get("ahi"), s["totalUsageMinutes"], s.get("leakRate95th"),
                    s["pressureMin"], s["pressureMax"], s["pressureMean"],
                    s.get("obstructiveEvents", 0), s.get("centralEvents", 0),
                    s.get("hypopneaEvents", 0), s.get("importSource", "sd_card"),
                    # By-session fields (migration 0010) get the same
                    # COALESCE-preserve semantics as ahi/leak_rate_95th: only
                    # the by-session import reports them, so a later daily-
                    # format sync of the same date (all nulls) must not wipe
                    # previously-synced by-session values. Trade-off, matching
                    # the ahi precedent: an intentional nil "clear" never
                    # propagates — acceptable because these fields have no
                    # client-side clear path.
                    s.get("rdiEvents"), s.get("reraEvents"),
                    s.get("spo2Avg"), s.get("spo2Min"), s.get("pulseAvg"),
                    s.get("pressure95th"), s.get("leakAvg"), s.get("leakMax"),
                ),
            )
        return len(sessions)

    # Names of the seven overnight clinical stats columns added in this PR.
    # Used to build the per-version ON CONFLICT clause below — Codable
    # `encodeIfPresent` makes "intentional nil" indistinguishable from "older
    # client doesn't know" at the JSON level, so we use a syncSchemaVersion
    # flag in the payload to disambiguate at the server boundary.
    _OVERNIGHT_STATS_COLUMNS = (
        "spo2_nadir_overnight",
        # spo2_nadir_opportunistic — source-stratified Apple-Watch-only nadir
        # added in PR #142. Same clear-on-missing semantics as the other
        # overnight stats: v>=2 clients (which is everything currently
        # shipping) send EXCLUDED for the actual value; older clients
        # don't know the key so it stays null via the COALESCE branch.
        "spo2_nadir_opportunistic",
        "spo2_time_below_90_min",
        "spo2_desats_count",
        "glucose_std_dev",
        "glucose_cv",
        "glucose_min",
        "glucose_max",
    )

    def _overnight_stats_update_clause(schema_version):
        """Return the SET fragment for the seven overnight stat columns.

        v >= 2: client knows the schema; missing key in payload is an
        intentional nil clear, so use EXCLUDED unconditionally.
        v == 1 (or absent): client may simply not know about these fields,
        so preserve any previously-synced non-null value via COALESCE.
        """
        if schema_version >= 2:
            return ",\n                       ".join(
                f"{col} = EXCLUDED.{col}" for col in _OVERNIGHT_STATS_COLUMNS
            )
        return ",\n                       ".join(
            f"{col} = COALESCE(EXCLUDED.{col}, health_snapshots.{col})"
            for col in _OVERNIGHT_STATS_COLUMNS
        )

    def _data_quality_update_clause(schema_version):
        """Return the SET fragment for the `data_quality` JSONB column.

        Same shape as `_overnight_stats_update_clause`, but the version
        boundary is 3 (this column was introduced after the overnight stats
        in PR #122). v >= 3 clients know the field, so missing key = clear.
        v <= 2 clients may simply not know about it, so preserve.
        """
        if schema_version >= 3:
            return "data_quality = EXCLUDED.data_quality"
        return "data_quality = COALESCE(EXCLUDED.data_quality, health_snapshots.data_quality)"

    # SpO2 source-basis columns (F-092), added at syncSchemaVersion 5.
    _SPO2_BASIS_COLUMNS = ("spo2_aggregate_source", "spo2_burden_source")

    # Allowed values for the SpO2 source-basis columns — mirrors the iOS
    # `SpO2SourceBasis` enum raw values. Anything else is coerced to NULL at
    # ingest so a malformed value can't round-trip back to iOS and decode to
    # nil there (which would silently suppress the mixed-provenance
    # disclosure). Coerce rather than reject: one bad basis string shouldn't
    # fail the whole snapshot batch, and NULL is the correct "unknown" state.
    _ALLOWED_SPO2_BASIS = {"oximeter", "mixed"}

    def _coerce_spo2_basis(value):
        return value if value in _ALLOWED_SPO2_BASIS else None

    def _spo2_basis_update_clause(schema_version):
        """Return the SET fragment for the two SpO2 source-basis columns.

        Same shape as the overnight-stats clause, version boundary 5. v >= 5
        clients know these keys, so a missing key is an intentional clear
        (EXCLUDED). v <= 4 clients predate the columns and never send them, so
        preserve any previously-synced basis via COALESCE rather than nulling
        it when such a client re-syncs the same date.
        """
        if schema_version >= 5:
            return ",\n                       ".join(
                f"{col} = EXCLUDED.{col}" for col in _SPO2_BASIS_COLUMNS
            )
        return ",\n                       ".join(
            f"{col} = COALESCE(EXCLUDED.{col}, health_snapshots.{col})"
            for col in _SPO2_BASIS_COLUMNS
        )

    def _upsert_health_snapshots(cur, snapshots, schema_version=1):
        overnight_clause = _overnight_stats_update_clause(schema_version)
        data_quality_clause = _data_quality_update_clause(schema_version)
        spo2_basis_clause = _spo2_basis_update_clause(schema_version)
        for s in snapshots:
            # `dataQuality` may arrive as a Python dict (from JSON decode) or a
            # JSON-encoded string (older Swift Codable shapes). psycopg2 needs a
            # string for JSONB binding; serialize dicts here, validate strings
            # before passing them through. A malformed JSON string would cause
            # Postgres to reject the entire batch with a 500 — coerce invalid
            # strings to NULL so one bad blob can't take down sync.
            data_quality = s.get("dataQuality")
            if isinstance(data_quality, (dict, list)):
                data_quality = json.dumps(data_quality)
            elif isinstance(data_quality, str):
                try:
                    parsed = json.loads(data_quality)
                    data_quality = json.dumps(parsed)
                except (json.JSONDecodeError, TypeError):
                    app.logger.warning(
                        "Discarding malformed dataQuality string for snapshot date=%s",
                        s.get("date"),
                    )
                    data_quality = None
            # Justification for the nosec below: overnight_clause,
            # spo2_basis_clause, and data_quality_clause are built exclusively
            # from hardcoded module-level column tuples (_OVERNIGHT_STATS_COLUMNS,
            # _SPO2_BASIS_COLUMNS) and fixed literal strings selected by an
            # integer schema_version comparison, never from request-controlled
            # text (see _overnight_stats_update_clause, _spo2_basis_update_clause,
            # _data_quality_update_clause above).
            cur.execute(
                f"""INSERT INTO health_snapshots (
                       date, hrv_avg, hrv_min, resting_hr,
                       sleep_duration_min, sleep_deep_min, sleep_rem_min, sleep_core_min, sleep_awake_min,
                       skin_temp_deviation, skin_temp_wrist, respiratory_rate, spo2_avg,
                       spo2_nadir_overnight, spo2_nadir_opportunistic,
                       spo2_time_below_90_min, spo2_desats_count,
                       spo2_aggregate_source, spo2_burden_source,
                       steps, active_calories, exercise_minutes,
                       environmental_sound_avg, bp_systolic, bp_diastolic, blood_glucose_avg,
                       glucose_std_dev, glucose_cv, glucose_min, glucose_max,
                       cpap_ahi, cpap_usage_minutes,
                       barometric_pressure_avg_kpa, barometric_pressure_change_kpa,
                       data_quality)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                           %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                           %s, %s)
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
                       {overnight_clause},
                       {spo2_basis_clause},
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
                       barometric_pressure_change_kpa = EXCLUDED.barometric_pressure_change_kpa,
                       {data_quality_clause}""",  # nosec B608
                (
                    s["date"], s.get("hrvAvg"), s.get("hrvMin"), s.get("restingHR"),
                    s.get("sleepDurationMin"), s.get("sleepDeepMin"), s.get("sleepREMMin"),
                    s.get("sleepCoreMin"), s.get("sleepAwakeMin"),
                    s.get("skinTempDeviation"), s.get("skinTempWrist"), s.get("respiratoryRate"), s.get("spo2Avg"),
                    s.get("spo2NadirOvernight"), s.get("spo2NadirOpportunistic"),
                    s.get("spo2TimeBelow90Min"), s.get("spo2DesatsCount"),
                    _coerce_spo2_basis(s.get("spo2AggregateSource")),
                    _coerce_spo2_basis(s.get("spo2BurdenSource")),
                    s.get("steps"), s.get("activeCalories"), s.get("exerciseMinutes"),
                    s.get("environmentalSoundAvg"), s.get("bpSystolic"), s.get("bpDiastolic"),
                    s.get("bloodGlucoseAvg"),
                    s.get("glucoseStdDev"), s.get("glucoseCV"),
                    s.get("glucoseMin"), s.get("glucoseMax"),
                    s.get("cpapAHI"), s.get("cpapUsageMinutes"),
                    s.get("barometricPressureAvgKPa"), s.get("barometricPressureChangeKPa"),
                    data_quality,
                ),
            )
        return len(snapshots)

    def _upsert_quantity_health_samples(cur, samples):
        """Upsert per-sample HealthKit quantity rows (id = HKSample.uuid).

        Replays update value, provenance, AND identity columns
        (timestamp, metric_type, unit_string, source_bundle_id) because
        HealthKit can issue retroactive corrections that change a sample's
        timestamp or unit while keeping the same uuid (e.g., CGM backfills,
        sensor recalibration). group_id uses COALESCE so a previously-set
        correlation link isn't accidentally cleared by a replay that omits it.

        Uses ``execute_values`` so a 1000-sample sync becomes one round trip
        instead of 1000 individual ``cur.execute`` calls. Note: this batches
        all rows into a single INSERT — one bad row aborts the whole call,
        so callers relying on per-row error isolation must split the batch
        themselves.
        """
        if not samples:
            return 0
        rows = [
            (
                s["id"], s["timestamp"], s["metricType"], s["value"],
                s["unitString"], s["sourceBundleID"],
                s.get("sourceName"), s.get("deviceModel"), s.get("groupId"),
            )
            for s in samples
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO quantity_health_samples (
                   id, timestamp, metric_type, value, unit_string,
                   source_bundle_id, source_name, device_model, group_id)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   timestamp = EXCLUDED.timestamp,
                   metric_type = EXCLUDED.metric_type,
                   value = EXCLUDED.value,
                   unit_string = EXCLUDED.unit_string,
                   source_bundle_id = EXCLUDED.source_bundle_id,
                   source_name = EXCLUDED.source_name,
                   device_model = EXCLUDED.device_model,
                   group_id = COALESCE(
                       EXCLUDED.group_id,
                       quantity_health_samples.group_id
                   )""",
            rows,
        )
        return len(samples)

    def _upsert_sleep_stage_events(cur, events):
        """Upsert per-event HealthKit sleep stage rows (id = HKSample.uuid).

        Batched via ``execute_values`` for the same reason as
        ``_upsert_quantity_health_samples`` — one round trip per sync instead
        of one per row.
        """
        if not events:
            return 0
        rows = [
            (
                e["id"], e["startTime"], e["endTime"], e["stage"],
                e["sourceBundleID"], e.get("sourceName"), e.get("deviceModel"),
            )
            for e in events
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO sleep_stage_events (
                   id, start_time, end_time, stage,
                   source_bundle_id, source_name, device_model)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   start_time = EXCLUDED.start_time,
                   end_time = EXCLUDED.end_time,
                   stage = EXCLUDED.stage,
                   source_bundle_id = EXCLUDED.source_bundle_id,
                   source_name = EXCLUDED.source_name,
                   device_model = EXCLUDED.device_model""",
            rows,
        )
        return len(events)

    def _coerce_summary_json(value):
        """Normalize the iOS-side ``summaryJSON`` field into a JSONB-ready
        value before insert.

        The iOS ``SensorSession`` model stores ``summaryJSON`` as a
        ``String?`` (the JSON-encoded HRV summary), so a naive Phase-3b
        client would send the encoded string over the wire. Passing that
        string through ``json.dumps`` would double-encode it and Postgres
        would store ``"{...}"`` (a JSON *string*) instead of a JSON object,
        silently breaking key lookups like
        ``summary_json->>'rmssdMean'``.

        Tolerate both shapes: if the field is already a string, decode it
        first; if a future client decodes before sending we accept the
        dict as-is. Malformed strings are dropped (column is nullable) so
        a single bad payload can't poison the upsert batch.
        """
        if value is None:
            return None
        if isinstance(value, str):
            try:
                decoded = json.loads(value)
            except (TypeError, ValueError):
                return None
            return psycopg2.extras.Json(decoded)
        return psycopg2.extras.Json(value)

    def _upsert_sensor_sessions(cur, sessions):
        """Upsert Polar H10 (and future BLE-strap) recording sessions.

        ``id`` is the iOS UUID so replays / partial-row updates (start row
        first, fill summary on finalize, optionally attach archive later)
        are idempotent. ``rr_archive`` is NOT touched in this path — the
        binary upload lives at ``POST /api/sensor_sessions/<id>/rr_archive``
        so callers can decide whether to ship the multi-hundred-KB blob.

        ``interruption_count`` uses GREATEST rather than a plain overwrite:
        the count is monotonically non-decreasing over a session's life, so
        a payload built before a finalize (in flight while the finalize
        landed client-side) can only ever carry a stale-low value. GREATEST
        keeps the replay idempotent without letting the stale payload
        regress the finalized count. COALESCE doesn't help here because the
        stale value is 0-or-more, never NULL.
        """
        if not sessions:
            return 0
        rows = [
            (
                s["id"], s["source"], s["startTime"], s.get("endTime"),
                s.get("batteryAtStart"), s.get("interruptionCount", 0),
                _coerce_summary_json(s.get("summaryJSON")),
            )
            for s in sessions
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO sensor_sessions (
                   id, source, start_time, end_time,
                   battery_at_start, interruption_count, summary_json)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   source = EXCLUDED.source,
                   start_time = EXCLUDED.start_time,
                   end_time = COALESCE(
                       EXCLUDED.end_time,
                       sensor_sessions.end_time
                   ),
                   battery_at_start = COALESCE(
                       EXCLUDED.battery_at_start,
                       sensor_sessions.battery_at_start
                   ),
                   interruption_count = GREATEST(
                       EXCLUDED.interruption_count,
                       sensor_sessions.interruption_count
                   ),
                   summary_json = COALESCE(
                       EXCLUDED.summary_json,
                       sensor_sessions.summary_json
                   )""",
            rows,
        )
        return len(sessions)

    def _upsert_hrv_readings(cur, readings):
        """Upsert per-minute HRVReading rows produced by HRVSessionRecorder.

        FK to sensor_sessions; the iOS sync orders parent sessions before
        their children so this never hits an FK violation in normal
        operation. lf_power / hf_power / lf_hf_ratio are nullable (per-
        minute windows with <30 RR intervals have time-domain only).
        """
        if not readings:
            return 0
        rows = [
            (
                r["id"], r["sessionId"], r["timestamp"],
                r["rmssd"], r["sdnn"], r["pnn50"],
                r.get("lfPower"), r.get("hfPower"), r.get("lfHfRatio"),
                r["source"],
            )
            for r in readings
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO hrv_readings (
                   id, session_id, timestamp,
                   rmssd, sdnn, pnn50,
                   lf_power, hf_power, lf_hf_ratio, source)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   session_id = EXCLUDED.session_id,
                   timestamp = EXCLUDED.timestamp,
                   rmssd = EXCLUDED.rmssd,
                   sdnn = EXCLUDED.sdnn,
                   pnn50 = EXCLUDED.pnn50,
                   lf_power = EXCLUDED.lf_power,
                   hf_power = EXCLUDED.hf_power,
                   lf_hf_ratio = EXCLUDED.lf_hf_ratio,
                   source = EXCLUDED.source""",
            rows,
        )
        return len(readings)

    def _upsert_accel_spectrograms(cur, spectrograms):
        """Upsert 10-second Watch accelerometer FFT windows.

        ``id`` is the iOS UUID so replays are idempotent (same
        ``ON CONFLICT (id) DO UPDATE`` contract as hrv_readings).
        ``sessionId`` is optional and maps to a nullable, non-FK
        ``session_id`` column: these rows reference watch-local capture
        sessions that never materialize as sensor_sessions rows, so a
        foreign key would reject every Watch-origin batch.
        """
        if not spectrograms:
            return 0
        rows = [
            (
                s["id"], s.get("sessionId"), s["timestamp"],
                s["tremorBandPower"], s["breathingBandPower"],
                s["fidgetBandPower"], s["activityLevel"],
            )
            for s in spectrograms
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO accel_spectrograms (
                   id, session_id, timestamp,
                   tremor_band_power, breathing_band_power,
                   fidget_band_power, activity_level)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   session_id = EXCLUDED.session_id,
                   timestamp = EXCLUDED.timestamp,
                   tremor_band_power = EXCLUDED.tremor_band_power,
                   breathing_band_power = EXCLUDED.breathing_band_power,
                   fidget_band_power = EXCLUDED.fidget_band_power,
                   activity_level = EXCLUDED.activity_level""",
            rows,
        )
        return len(spectrograms)

    def _upsert_derived_breathing_rates(cur, rates):
        """Upsert per-minute breathing rates derived from Watch wrist motion.

        Same idempotent-replay and nullable non-FK ``session_id`` contract
        as ``_upsert_accel_spectrograms`` above. ``source`` is required
        ("accelerometer" or "healthkit_sleep") — the iOS model field is
        non-optional, so no "unknown" sentinel path exists here.
        """
        if not rates:
            return 0
        rows = [
            (
                r["id"], r.get("sessionId"), r["timestamp"],
                r["breathsPerMinute"], r["confidence"], r["source"],
            )
            for r in rates
        ]
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO derived_breathing_rates (
                   id, session_id, timestamp,
                   breaths_per_minute, confidence, source)
               VALUES %s
               ON CONFLICT (id) DO UPDATE SET
                   session_id = EXCLUDED.session_id,
                   timestamp = EXCLUDED.timestamp,
                   breaths_per_minute = EXCLUDED.breaths_per_minute,
                   confidence = EXCLUDED.confidence,
                   source = EXCLUDED.source""",
            rows,
        )
        return len(rates)

    def _upsert_barometric_readings(cur, readings):
        # Batched via execute_values (one round trip) to match its unbounded
        # time-series siblings (quantity samples, sensor sessions, HRV readings,
        # sleep events); it was the last per-row execute loop, so a night's
        # worth of readings meant one round trip per row (F-060).
        if not readings:
            return 0
        # Collapse within-batch duplicate timestamps (last wins) BEFORE the
        # upsert: `ON CONFLICT (timestamp) DO UPDATE` cannot touch the same
        # row twice in one statement (CardinalityViolation → the whole sync
        # 500s). Two barometric captures can legitimately share a timestamp,
        # and a full re-sync exports the entire history in one batch, so the
        # collision surfaces there even when incremental windows dodged it.
        # A dict keyed by timestamp preserves last-write-wins, matching the
        # DO UPDATE semantics for the cross-batch case.
        deduped = {
            r["timestamp"]: (r["timestamp"], r["pressureKPa"], r["relativeAltitudeM"])
            for r in readings
        }
        rows = list(deduped.values())
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO barometric_readings (timestamp, pressure_kpa, relative_altitude_m)
               VALUES %s
               ON CONFLICT (timestamp) DO UPDATE SET
                   pressure_kpa = EXCLUDED.pressure_kpa,
                   relative_altitude_m = EXCLUDED.relative_altitude_m""",
            rows,
        )
        return len(rows)

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
                       date_filled, pharmacy_name, notes)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (rx_number) DO UPDATE SET
                       medication_name = EXCLUDED.medication_name,
                       dose_mg = EXCLUDED.dose_mg,
                       dose_description = EXCLUDED.dose_description,
                       date_filled = EXCLUDED.date_filled,
                       pharmacy_name = EXCLUDED.pharmacy_name,
                       notes = EXCLUDED.notes""",
                # `or ""`: .get's default only covers ABSENT keys — an explicit
                # JSON null comes through as None and would violate the TEXT
                # NOT NULL columns, 500ing the whole sync transaction.
                (rx["rxNumber"], rx["medicationName"], rx["doseMg"],
                 rx.get("doseDescription") or "", rx["dateFilled"],
                 rx.get("pharmacyName") or "", rx.get("notes") or ""),
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
                updates.append(sql.SQL("date_of_birth = %s"))
                values.append(dob)
            if sex and existing[2] is None:  # gender is NULL
                updates.append(sql.SQL("gender = %s"))
                values.append(sex)
            if updates:
                updates.append(sql.SQL("updated_at = NOW()"))
                values.append(existing[0])
                cur.execute(
                    sql.SQL("UPDATE patient_profile SET {} WHERE id = %s").format(
                        sql.SQL(", ").join(updates)
                    ),
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
        """Upsert song occurrences; returns (upserted_count, skipped_count).

        Occurrences that can't be linked to a songs row are counted as
        skipped, not upserted: the iOS client advances its sync cursor after
        a 200 response, so an occurrence silently folded into the upserted
        count would never be re-sent and the record would be lost with no
        signal anywhere. The skip count is surfaced in the /api/sync response
        (and therefore in sync_log.record_counts) instead of failing the
        whole sync.
        """
        upserted = 0
        skipped = 0
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
                # Can't link occurrence without a song. Log timestamp only —
                # notes may contain personal content.
                skipped += 1
                app.logger.warning(
                    "Skipping unlinkable song occurrence at %s (no matching genius_id or server_id)",
                    o.get("timestamp"),
                )
                continue

            cur.execute(
                """INSERT INTO song_occurrences (song_id, timestamp, source, anxiety_entry_id, notes)
                   VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (song_id, timestamp, source) DO NOTHING""",
                (song_id, o["timestamp"], o.get("source") or "standalone",
                 o.get("anxietyEntryTimestamp"), o.get("notes")),
            )
            upserted += 1
        return upserted, skipped

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
            if entity in BULK_EXCLUDED_ENTITIES:
                continue
            result[entity] = _query_entity(cur, entity, since)

        # Tell the client which entities it must page in separately, rather than
        # having it hard-code the list and silently miss one if this set grows.
        result["pagedEntities"] = sorted(BULK_EXCLUDED_ENTITIES)
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
        try:
            limit, offset = _parse_paging(request.args)
        except (TypeError, ValueError):
            return jsonify({"error": "limit and offset must be integers"}), 400

        if limit is not None and entity not in ENTITY_PAGE_TIEBREAK:
            # Serving this unpaged would silently ignore the client's limit;
            # serving it paged would order by a non-unique key and skip/repeat
            # rows. Refuse instead of doing either quietly.
            return jsonify({"error": f"Entity does not support paging: {entity}"}), 400

        rows = _query_entity(cur, entity, since, limit=limit, offset=offset)
        payload = {entity: rows, "exportDate": datetime.now(timezone.utc).isoformat()}

        if limit is not None:
            payload["limit"] = limit
            payload["offset"] = offset or 0
            # Count only on the first page. The client needs the total once (to
            # verify it received every row rather than inferring completion from
            # a short page); running count(*) on all ~50 pages of a 250k-row
            # restore is ~49 full scans for an answer that cannot change.
            if not payload["offset"]:
                # table/time_col are identifiers from the hardcoded ENTITY_QUERIES
                # dict, keyed by `entity` which was already validated against
                # ENTITY_QUERIES above — never request-controlled text. Composed
                # via psycopg2.sql.Identifier rather than f-string interpolation.
                table, time_col, _ = ENTITY_QUERIES[entity]
                if since and time_col:
                    cur.execute(
                        sql.SQL("SELECT count(*) AS n FROM {} WHERE {} >= %s").format(
                            sql.Identifier(table), sql.Identifier(time_col)
                        ),
                        (since,),
                    )
                else:
                    cur.execute(
                        sql.SQL("SELECT count(*) AS n FROM {}").format(sql.Identifier(table))
                    )
                count_row = cur.fetchone()
                payload["total"] = count_row["n"] if count_row else 0

        return jsonify(payload)

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
        "sensorSessions": ("sensor_sessions", "start_time", "start_time"),
        "hrvReadings": ("hrv_readings", "timestamp", "timestamp"),
        "accelSpectrograms": ("accel_spectrograms", "timestamp", "timestamp"),
        "derivedBreathingRates": ("derived_breathing_rates", "timestamp", "timestamp"),
        "songs": ("songs", None, "id"),
        "songOccurrences": ("song_occurrences", "timestamp", "timestamp"),
        "sleepStageEvents": ("sleep_stage_events", "start_time", "start_time"),
        "quantityHealthSamples": ("quantity_health_samples", "timestamp", "timestamp"),
    }

    # Entities too large to inline in the bulk /api/data payload. They sync UP
    # like everything else, but a restore must pull them DOWN page-by-page from
    # /api/data/<entity>?limit=&offset= instead.
    #
    # quantity_health_samples is ~250k rows / ~79 MB of JSON on a real device.
    # Inlining it would make /api/data a multi-tens-of-MB response that the app
    # then has to hold in memory as a parsed [[String: Any]] — a reliable way to
    # get the restore jetsammed. It was previously omitted from ENTITY_QUERIES
    # entirely, which meant it could sync up but never come back down: a fresh
    # install silently lost every EMAY oximetry sample (those are app-only, not
    # HealthKit-backed, so nothing else could re-derive them).
    BULK_EXCLUDED_ENTITIES = {"quantityHealthSamples"}

    # Entities that can be paged, and the UNIQUE column used to break ties in the
    # ORDER BY. Offset paging is only exact if the sort key is total; the sort
    # columns above (timestamp/date/name) are not unique, so a tiebreaker is
    # required or pages silently skip and repeat rows.
    #
    # Only these tables have an `id` column — the rest key on natural keys
    # (timestamp, date, name) and have no unique surrogate to order by. Paging
    # any other entity is rejected rather than served with an unstable order.
    ENTITY_PAGE_TIEBREAK = {
        "quantityHealthSamples": "id",
        "hrvReadings": "id",
        "sleepStageEvents": "id",
        "sensorSessions": "id",
        "accelSpectrograms": "id",
        "derivedBreathingRates": "id",
        "songs": "id",
        "songOccurrences": "id",
    }

    # Explicit column lists for entities where `SELECT *` would detoast a large
    # column the response never uses. sensor_sessions.rr_archive is an ~80-120KB
    # gzip BYTEA per overnight session that `_serialize_row` immediately nulls
    # out (the binary lives at GET .../rr_archive), so selecting it out of
    # Postgres into Python is pure waste (F-058). Any entity absent here uses *.
    ENTITY_SELECT_COLS = {
        "sensorSessions": (
            "id, source, start_time, end_time, battery_at_start, "
            "interruption_count, summary_json, created_at"
        ),
    }

    def _query_entity(cur, entity, since=None, limit=None, offset=None):
        # table/time_col/order_col/cols/tiebreak are all identifiers sourced
        # from the hardcoded ENTITY_QUERIES / ENTITY_SELECT_COLS /
        # ENTITY_PAGE_TIEBREAK dicts, keyed by `entity` — callers
        # (get_all_data/get_entity_data) only ever pass an `entity` already
        # validated against ENTITY_QUERIES. Composed via psycopg2.sql rather
        # than f-string interpolation.
        table, time_col, order_col = ENTITY_QUERIES[entity]
        cols = ENTITY_SELECT_COLS.get(entity, "*")
        cols_sql = (
            sql.SQL("*")
            if cols == "*"
            else sql.SQL(", ").join(sql.Identifier(c.strip()) for c in cols.split(","))
        )

        # A unique tiebreaker is appended whenever we page. LIMIT/OFFSET over a
        # non-unique sort key (timestamp collides constantly in per-second
        # oximetry) has no stable row order between requests, so pages would
        # silently skip some rows and repeat others. Ordering by
        # (order_col, tiebreak) is total, which makes offset paging exact.
        #
        # Only the entities in ENTITY_PAGE_TIEBREAK can be paged — most tables
        # here have NO `id` column (they use natural keys), so appending one
        # unconditionally would just make the query 500. get_entity_data rejects
        # a paging request for anything not listed.
        order = sql.SQL("{} DESC").format(sql.Identifier(order_col))
        if limit is not None:
            order = sql.SQL("{}, {}").format(order, sql.Identifier(ENTITY_PAGE_TIEBREAK[entity]))

        params = []
        query = sql.SQL("SELECT {cols} FROM {table}").format(cols=cols_sql, table=sql.Identifier(table))
        if since and time_col:
            query += sql.SQL(" WHERE {} >= %s").format(sql.Identifier(time_col))
            params.append(since)
        query += sql.SQL(" ORDER BY {}").format(order)
        if limit is not None:
            query += sql.SQL(" LIMIT %s OFFSET %s")
            params.extend([limit, offset or 0])

        cur.execute(query, tuple(params))
        rows = cur.fetchall()
        # Serialize dates/datetimes to ISO strings
        return [_serialize_row(r) for r in rows]

    # Upper bound on a single page. Big enough that ~250k samples restore in a
    # few dozen round trips, small enough that neither side holds a huge payload.
    MAX_PAGE_LIMIT = 10000

    def _parse_paging(args):
        """Parse and clamp ?limit=&offset=. Returns (limit, offset); (None, None) when
        no limit was requested.

        Raises ValueError on a malformed limit/offset. It must NOT fall back to an
        unpaged query: silently ignoring `?limit=abc` would return the entire table
        — ~79 MB for quantityHealthSamples — which turns a typo into an
        authenticated DoS and quietly bypasses MAX_PAGE_LIMIT.
        """
        raw_limit = args.get("limit")
        if raw_limit is None:
            return None, None
        limit = max(1, min(int(raw_limit), MAX_PAGE_LIMIT))
        offset = max(0, int(args.get("offset", 0)))
        return limit, offset

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

        # `k` is filtered against `allowed` above, but compose via
        # sql.Identifier (not f-string) for defense in depth.
        set_parts = []
        values = []
        for k, v in updates.items():
            set_parts.append(sql.SQL("{} = %s").format(sql.Identifier(k)))
            values.append(v)
        set_parts.append(sql.SQL("updated_at = NOW()"))
        values.append(song_id)

        cur.execute(
            sql.SQL("UPDATE songs SET {} WHERE id = %s RETURNING *").format(
                sql.SQL(", ").join(set_parts)
            ),
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
            elif isinstance(v, memoryview):
                # bytea columns (e.g. sensor_sessions.rr_archive) — drop the
                # binary payload from JSON responses; the metadata fields
                # alongside are what consumers need.
                result[k] = None
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
        # `table` iterates the hardcoded ENTITY_QUERIES dict — not request input.
        for entity, (table, _, _) in ENTITY_QUERIES.items():
            cur.execute(sql.SQL("SELECT COUNT(*) AS count FROM {}").format(sql.Identifier(table)))
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
    # Dev-only entry point — prod runs under gunicorn (see Dockerfile/CMD).
    # Defaults are safe-by-default (loopback, no debugger); opt into a LAN-
    # reachable host or the Werkzeug debugger explicitly via env vars, never
    # unconditionally (the debugger's evaluation console is a straight RCE
    # if it's ever reachable off localhost).
    app.run(
        host=os.environ.get("FLASK_RUN_HOST", "127.0.0.1"),
        port=8080,
        debug=os.environ.get("FLASK_DEBUG") == "1",
    )
