
import logging
import hashlib
from functools import wraps
from flask import Blueprint, jsonify, request, current_app, g
import psycopg2.extras

logger = logging.getLogger(__name__)

as11_bp = Blueprint("as11", __name__, url_prefix="/api/cpap/as11")


def get_db():
    return current_app.get_db()


def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "Missing Authorization header"}), 401

        token = auth[7:]
        key_hash = hashlib.sha256(token.encode()).hexdigest()

        db = get_db()
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT id, is_active FROM api_keys WHERE key_hash = %s",
                (key_hash,),
            )
            row = cur.fetchone()

        if not row or not row["is_active"]:
            return jsonify({"error": "Invalid or revoked API key"}), 401

        # Mirror the main server's require_api_key so AS11 traffic is reflected
        # in api_keys.last_used_at / request_count usage tracking.
        with db.cursor() as cur:
            cur.execute(
                "UPDATE api_keys SET last_used_at = NOW(), request_count = request_count + 1 WHERE id = %s",
                (row["id"],),
            )
        db.commit()

        g.api_key_id = row["id"]
        return f(*args, **kwargs)
    return decorated


def insert_stream_sample(db, bridge_id, ts_utc, channel, value, unit=None, session_id=None):
    """
    Accessor to insert a parsed stream sample from AS11 into the database.
    """
    with db.cursor() as cur:
        cur.execute("""
            INSERT INTO as11_stream_sample
            (bridge_id, ts_utc, channel, value, unit, session_id)
            VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (bridge_id, ts_utc, channel, value, unit, session_id))
        sample_id = cur.fetchone()[0]
        db.commit()
    return sample_id


def insert_therapy_session(db, bridge_id, start_utc, end_utc=None, mode=None,
                           set_pressure=None, min_pressure=None, max_pressure=None,
                           median_pressure=None, p95_leak=None, ahi=None,
                           event_counts=None, mask_on_fraction=None, source='as11',
                           settings_snapshot=None):
    """
    Accessor to insert a therapy session summary from AS11 into the database.
    """
    with db.cursor() as cur:
        cur.execute("""
            INSERT INTO as11_therapy_session
            (bridge_id, start_utc, end_utc, mode, set_pressure, min_pressure,
             max_pressure, median_pressure, p95_leak, ahi, event_counts,
             mask_on_fraction, source, settings_snapshot)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (
            bridge_id, start_utc, end_utc, mode, set_pressure, min_pressure,
            max_pressure, median_pressure, p95_leak, ahi,
            psycopg2.extras.Json(event_counts) if event_counts else None,
            mask_on_fraction, source,
            psycopg2.extras.Json(settings_snapshot) if settings_snapshot else None
        ))
        session_id = cur.fetchone()[0]
        db.commit()
    return session_id


@as11_bp.route("/live", methods=["GET"])
@require_api_key
def get_live():
    try:
        raw_limit = request.args.get("limit")
        limit = 1000 if raw_limit is None else int(raw_limit)
        if limit < 1:
            return jsonify({"error": "limit must be a positive integer"}), 400
        limit = min(limit, 10000)
    except ValueError:
        return jsonify({"error": "limit must be a positive integer"}), 400

    db = get_db()
    try:
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, bridge_id, ts_utc, channel, value, unit, ingest_ts_utc, session_id
                FROM as11_stream_sample
                ORDER BY ts_utc DESC
                LIMIT %s
            """, (limit,))
            samples = cur.fetchall()

        return jsonify({"samples": samples})
    except Exception as e:
        logger.error(f"Error fetching AS11 live samples: {e}")
        return jsonify({"error": "Internal server error"}), 500


@as11_bp.route("/sessions", methods=["GET"])
@require_api_key
def get_sessions():
    try:
        raw_limit = request.args.get("limit")
        limit = 50 if raw_limit is None else int(raw_limit)
        if limit < 1:
            return jsonify({"error": "limit must be a positive integer"}), 400
        limit = min(limit, 500)
    except ValueError:
        return jsonify({"error": "limit must be a positive integer"}), 400

    db = get_db()
    try:
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, bridge_id, start_utc, end_utc, mode, set_pressure,
                       min_pressure, max_pressure, median_pressure, p95_leak, ahi,
                       event_counts, mask_on_fraction, source, settings_snapshot, created_at
                FROM as11_therapy_session
                ORDER BY start_utc DESC
                LIMIT %s
            """, (limit,))
            sessions = cur.fetchall()

        return jsonify({"sessions": sessions})
    except Exception as e:
        logger.error(f"Error fetching AS11 sessions: {e}")
        return jsonify({"error": "Internal server error"}), 500
