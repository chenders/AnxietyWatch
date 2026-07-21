import time
import json
import hashlib
from flask import request, current_app
from flask_sock import Sock
import psycopg2.extras
from datetime import datetime, timezone

sock = Sock()

# Never stream stream-sample history older than this. The app stamps every
# sample in one frame with the same LOCAL receipt time, so an old backlog —
# a stale `since` cursor from a prior monitoring session, or a fresh connect
# that would otherwise start at id 0 and replay the oldest rows — drained over
# several polls would look "current" to the quality gate and could MASK a live
# desaturation (or fire on a resolved historical dip). Bounding every send to
# the recent window (>= the app's gate window + slack) means only genuinely
# recent samples ever reach the client; a legitimate short background/foreground
# resync still replays its (recent) gap. Keyed on ingest_ts_utc (the server's
# own clock, set at ingest) — NOT ts_utc — so a skewed bridge clock can't
# future-date rows past the window or hold the liveness state at STREAMING_OK.
STREAM_REPLAY_WINDOW_SECONDS = 70


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
    try:
        last_id = int(since) if since else 0
    except ValueError:
        last_id = 0

    while True:
        db = get_db()

        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, bridge_id, ts_utc, channel, value, unit, ingest_ts_utc, session_id
                FROM as11_stream_sample
                WHERE id > %s AND ingest_ts_utc > NOW() - (%s * INTERVAL '1 second')
                ORDER BY id ASC LIMIT 1000
            """, (last_id, STREAM_REPLAY_WINDOW_SECONDS))
            samples = cur.fetchall()

            # Newest row by primary key = latest ingest (id is SERIAL, monotonic
            # with ingest_ts_utc), so this reads the liveness timestamp off the
            # PK index instead of a MAX() full-table scan every poll.
            cur.execute("SELECT ingest_ts_utc FROM as11_stream_sample ORDER BY id DESC LIMIT 1")
            row = cur.fetchone()
            latest_ts = row['ingest_ts_utc'] if row else None

        # End the read transaction each iteration: this connection lives for the
        # whole WS session, and leaving a transaction open across every 2s poll
        # would pin an xmin snapshot and hold back (auto)vacuum over time.
        db.rollback()

        if samples:
            last_id = max(s['id'] for s in samples)
            for s in samples:
                if isinstance(s['ts_utc'], datetime):
                    s['ts_utc'] = s['ts_utc'].astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
                if isinstance(s['ingest_ts_utc'], datetime):
                    s['ingest_ts_utc'] = s['ingest_ts_utc'].astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

        state = "STREAM_STALLED"
        now_utc = datetime.now(timezone.utc)
        if latest_ts:
            if (now_utc - latest_ts).total_seconds() <= 15:
                state = "STREAMING_OK"
        response = {
            "samples": samples,
            "state": state
        }

        try:
            ws.send(json.dumps(response))
        except Exception:
            break

        # Optional: listen for client messages to handle ping/pong or close
        # but time.sleep is simpler if we just push.
        time.sleep(2.0)


@sock.route('/api/cpap/as11/ws')
def as11_ws(ws):
    as11_ws_handler(ws)
