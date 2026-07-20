import json
import hashlib
from flask import Blueprint, request, current_app
from flask_sock import Sock
import psycopg2.extras
from datetime import datetime, timezone

as11_ws_bp = Blueprint("as11_ws", __name__)
sock = Sock()


def get_db():
    return current_app.get_db()


def authenticate_ws_request():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False

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
        return False

    with db.cursor() as cur:
        cur.execute(
            "UPDATE api_keys SET last_used_at = NOW(), request_count = request_count + 1 WHERE id = %s",
            (row["id"],),
        )
    db.commit()
    return True


def as11_ws_handler(ws):
    if not authenticate_ws_request():
        ws.close(1008, "Unauthorized")
        return

    since = request.args.get("since")

    db = get_db()

    query = """
        SELECT id, bridge_id, ts_utc, channel, value, unit, ingest_ts_utc, session_id
        FROM as11_stream_sample
    """
    params = []

    if since:
        query += " WHERE id > %s"
        params.append(since)

    query += " ORDER BY id ASC LIMIT 1000"

    with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, tuple(params))
        samples = cur.fetchall()

    for s in samples:
        if isinstance(s['ts_utc'], datetime):
            s['ts_utc'] = s['ts_utc'].astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        if isinstance(s['ingest_ts_utc'], datetime):
            s['ingest_ts_utc'] = s['ingest_ts_utc'].astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    response = {
        "samples": samples,
        "state": "STREAMING_OK"
    }
    ws.send(json.dumps(response))


@sock.route('/api/cpap/as11/ws')
def as11_ws(ws):
    as11_ws_handler(ws)
