
import logging
from flask import Blueprint, jsonify, request, current_app
import psycopg2.extras

logger = logging.getLogger(__name__)

as11_bp = Blueprint("as11", __name__, url_prefix="/api/cpap/as11")


def get_db():
    return current_app.get_db()


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
def get_live():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Unauthorized"}), 401

    db = get_db()
    try:
        limit = min(request.args.get("limit", 1000, type=int), 10000)
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
def get_sessions():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Unauthorized"}), 401

    db = get_db()
    try:
        limit = min(request.args.get("limit", 50, type=int), 500)
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, bridge_id, start_utc, end_utc, mode, set_pressure,
                       min_pressure, max_pressure, median_pressure, p95_leak, ahi,
                       event_counts, mask_on_fraction, source, settings_snapshot, created_a
                FROM as11_therapy_session
                ORDER BY start_utc DESC
                LIMIT %s
            """, (limit,))
            sessions = cur.fetchall()

        return jsonify({"sessions": sessions})
    except Exception as e:
        logger.error(f"Error fetching AS11 sessions: {e}")
        return jsonify({"error": "Internal server error"}), 500
