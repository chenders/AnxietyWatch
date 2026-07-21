"""Redundant alert-channel endpoints: live-upload append, backstop, heartbeat.

Sub-project C Task 4 (server redundant alert channel). This blueprint is the
*secondary* safety path (design §1): it can only ever ADD an alert, never
suppress or downgrade the on-device decision.

Flow (design §4):

    phone (armed BLE session) --POST /samples--> session_sample_buffer
                                    |
                    ┌───────────────┴────────────────┐
        backstop (sustained low SpO2)      heartbeat sweep (no upload for N)
                    └──────────── APNs push (once per event) ───────────┘

Two independent raises, both idempotent per ``(session_id, kind)`` via the
``alert_event`` ledger:

* **Backstop** — evaluated on every append over a *recent* (``ts_utc``-bounded)
  window, so a late catch-up upload of old samples can't fire it (the AS11
  stale-backlog lesson). Delegates the decision to the pure ``backstop``
  evaluator; this module never re-implements the personalized on-device fusion.
* **Heartbeat** — a periodic sweep (``run_heartbeat_sweep``, cron-invoked in
  prod; there is no in-process scheduler) that raises "monitoring may have
  stopped" when an *armed* session's server-side ingest goes silent past
  ``HEARTBEAT_TIMEOUT_SECONDS``. Liveness keys on ``ingest_ts_utc`` (server
  clock — skew-proof "when did we last hear from the phone"). An append clears
  the session's heartbeat alert, so a later silence re-fires (design §6
  "resumes → clears").

Fail-safe: a missing/failed APNs push is logged (own-failure-visible, design §5)
but never crashes an upload — A carries the fast path. Credentials come from env
only; tokens/keys/JWTs are never logged (only kind + session id + metadata).
"""
import hashlib
import logging
from datetime import datetime, timedelta, timezone
from functools import wraps

import psycopg2.extras
from flask import Blueprint, current_app, g, jsonify, request

import apns
import backstop

logger = logging.getLogger(__name__)

alert_channel_bp = Blueprint("alert_channel", __name__, url_prefix="/api/alert-channel")

# Alert kinds mirror the APNs payload builder's kinds.
KIND_BACKSTOP = apns.KIND_BACKSTOP
KIND_HEARTBEAT = apns.KIND_HEARTBEAT

# --- Tunables ---------------------------------------------------------------

# Recent-window the backstop is evaluated over, in seconds. Bounded by the
# sample's own ts_utc (consistent with the evaluator's sustain math) so an
# old-timestamped catch-up batch is excluded rather than scored as current.
# Structurally kept >= the evaluator's sustain window so a full sustained run
# always fits inside it (no separate assert -> no bandit B101).
ALERT_EVAL_WINDOW_SECONDS = max(300.0, backstop.SUSTAIN_SECONDS * 2.0)

# How long a session's server-side ingest may go silent before the heartbeat
# raises "monitoring may have stopped" (mirrors the on-device dead-man's-switch).
HEARTBEAT_TIMEOUT_SECONDS = 120.0

# Only sweep sessions whose last upload is within this lookback: past it the
# session is treated as ended, not silently-stalled, so an old session in the
# buffer never re-alerts on every sweep. (Explicit disarm is a Task 5 concern.)
HEARTBEAT_ACTIVE_LOOKBACK_SECONDS = 3600.0

# Ship Time-Sensitive pushes until sub-project A's Critical Alerts entitlement
# lands (design §3 / §8); flip to True once it does.
PUSH_CRITICAL = False


def get_db():
    return current_app.get_db()


def require_api_key(f):
    """Bearer-token auth against the api_keys table (mirrors api/as11.py)."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "Missing Authorization header"}), 401

        token = auth[7:]
        key_hash = hashlib.sha256(token.encode()).hexdigest()

        db = get_db()
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT id, is_active FROM api_keys WHERE key_hash = %s", (key_hash,))
            row = cur.fetchone()

        if not row or not row["is_active"]:
            return jsonify({"error": "Invalid or revoked API key"}), 401

        with db.cursor() as cur:
            cur.execute(
                "UPDATE api_keys SET last_used_at = NOW(), request_count = request_count + 1 WHERE id = %s",
                (row["id"],),
            )
        db.commit()

        g.api_key_id = row["id"]
        return f(*args, **kwargs)
    return decorated


# --- Persistence helpers ----------------------------------------------------


def insert_buffer_sample(db, session_id, ts_utc, channel, value, ingest_ts_utc=None):
    """Append one sample to the per-session buffer; returns its id.

    ``ingest_ts_utc`` defaults to the server clock (NOW()); it is injectable so
    tests can backdate a session's last-heard-from time for the heartbeat sweep.
    """
    with db.cursor() as cur:
        if ingest_ts_utc is None:
            cur.execute(
                "INSERT INTO session_sample_buffer (session_id, ts_utc, channel, value) "
                "VALUES (%s, %s, %s, %s) RETURNING id",
                (session_id, ts_utc, channel, value),
            )
        else:
            cur.execute(
                "INSERT INTO session_sample_buffer (session_id, ts_utc, channel, value, ingest_ts_utc) "
                "VALUES (%s, %s, %s, %s, %s) RETURNING id",
                (session_id, ts_utc, channel, value, ingest_ts_utc),
            )
        sample_id = cur.fetchone()[0]
    db.commit()
    return sample_id


def _registered_tokens(db):
    with db.cursor() as cur:
        cur.execute("SELECT token, env FROM device_push_token")
        return cur.fetchall()


def _clear_alert(db, session_id, kind):
    """Drop a session's alert of ``kind`` so a future occurrence can re-fire."""
    with db.cursor() as cur:
        cur.execute("DELETE FROM alert_event WHERE session_id = %s AND kind = %s", (session_id, kind))
    db.commit()


def push_alert(db, kind, session_id, *, critical=False):
    """Send one APNs push of ``kind`` to every registered device. Never raises.

    Returns the number of devices APNs accepted. A missing token registry or
    missing APNs config is logged (own-failure-visible) and returns 0 — the
    redundant channel degrades quietly rather than crashing an upload.
    """
    tokens = _registered_tokens(db)
    if not tokens:
        logger.warning("alert-channel: %s raised for session but no device push tokens registered", kind)
        return 0
    try:
        config = apns.ApnsConfig.from_env()
    except apns.ApnsConfigError:
        logger.warning("alert-channel: %s raised for session but APNs is not configured (env missing)", kind)
        return 0

    payload = apns.build_payload(kind, critical=critical)
    sent = 0
    for token, env in tokens:
        result = apns.send(token, payload, critical=critical, config=config, use_sandbox=(env == "sandbox"))
        if result.ok:
            sent += 1
    return sent


def _maybe_raise(db, session_id, kind, now, push):
    """Idempotently raise ``kind`` for ``session_id``: alert + push exactly once
    per un-cleared event. Returns True iff this call raised (a new alert)."""
    with db.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM alert_event WHERE session_id = %s AND kind = %s LIMIT 1",
            (session_id, kind),
        )
        if cur.fetchone():
            return False  # already alerted for this event
        cur.execute(
            "INSERT INTO alert_event (session_id, kind, ts_utc) VALUES (%s, %s, %s)",
            (session_id, kind, now),
        )
    db.commit()
    # Push after the ledger commit so the event is recorded even if delivery
    # fails; push_alert never raises, but guard anyway (fail-safe).
    try:
        push(db, kind, session_id, critical=PUSH_CRITICAL)
    except Exception as exc:  # pragma: no cover - push_alert already swallows
        logger.warning("alert-channel push raised for %s: %s", kind, type(exc).__name__)
    return True


# --- Core logic (clock-injected, test-callable) -----------------------------


def append_samples(db, session_id, samples, now, push=None):
    """Buffer ``samples`` for ``session_id`` and evaluate the backstop.

    ``samples`` is an iterable of ``(ts_utc, channel, value)``. Appending clears
    any pending heartbeat alert (uploads resumed). The backstop is evaluated
    over the recent ts_utc-bounded window and raised idempotently. ``now`` is
    injected; ``push`` defaults to the real APNs sender.
    """
    if push is None:
        push = push_alert

    buffered = 0
    for ts_utc, channel, value in samples:
        insert_buffer_sample(db, session_id, ts_utc, channel, value)
        buffered += 1

    # Uploads are flowing again -> the "monitoring stopped" alert no longer holds.
    _clear_alert(db, session_id, KIND_HEARTBEAT)

    window_start = now - timedelta(seconds=ALERT_EVAL_WINDOW_SECONDS)
    with db.cursor() as cur:
        cur.execute(
            "SELECT ts_utc, channel, value FROM session_sample_buffer "
            "WHERE session_id = %s AND ts_utc >= %s",
            (session_id, window_start),
        )
        window = [backstop.Sample(ts, channel, float(value)) for ts, channel, value in cur.fetchall()]

    verdict = backstop.evaluate(window, now)
    pushed = False
    if verdict.raised:
        pushed = _maybe_raise(db, session_id, KIND_BACKSTOP, now, push)

    return {
        "buffered": buffered,
        "backstop_raised": verdict.raised,
        "pushed": pushed,
        "last_ack_utc": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def run_heartbeat_sweep(db, now, push=None):
    """Raise "monitoring may have stopped" for each armed session gone silent.

    A session is a candidate when its most recent server-side ingest is older
    than ``HEARTBEAT_TIMEOUT_SECONDS`` but still within
    ``HEARTBEAT_ACTIVE_LOOKBACK_SECONDS`` (so ended/ancient sessions are not
    re-alerted). Idempotent per session; cleared by the next append. Returns the
    list of session ids that raised on this sweep.
    """
    if push is None:
        push = push_alert

    silent_before = now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS)
    active_after = now - timedelta(seconds=HEARTBEAT_ACTIVE_LOOKBACK_SECONDS)
    with db.cursor() as cur:
        cur.execute(
            "SELECT session_id FROM session_sample_buffer "
            "GROUP BY session_id "
            "HAVING MAX(ingest_ts_utc) < %s AND MAX(ingest_ts_utc) >= %s",
            (silent_before, active_after),
        )
        candidates = [row[0] for row in cur.fetchall()]

    raised = []
    for session_id in candidates:
        if _maybe_raise(db, session_id, KIND_HEARTBEAT, now, push):
            raised.append(session_id)
    return raised


# --- HTTP endpoints ---------------------------------------------------------


def _parse_ts(value):
    dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


@alert_channel_bp.route("/samples", methods=["POST"])
@require_api_key
def post_samples():
    body = request.get_json(silent=True) or {}
    session_id = body.get("session_id")
    raw = body.get("samples")
    if not session_id or not isinstance(raw, list):
        return jsonify({"error": "session_id and samples[] are required"}), 400

    samples = []
    for item in raw:
        try:
            samples.append((_parse_ts(item["ts_utc"]), str(item["channel"]), float(item["value"])))
        except (KeyError, TypeError, ValueError):
            return jsonify({"error": "each sample needs ts_utc, channel, value"}), 400

    db = get_db()
    try:
        result = append_samples(db, session_id, samples, datetime.now(timezone.utc))
    except Exception as exc:
        logger.error("alert-channel append failed: %s", type(exc).__name__)
        return jsonify({"error": "Internal server error"}), 500
    return jsonify(result)


@alert_channel_bp.route("/push-token", methods=["POST"])
@require_api_key
def post_push_token():
    body = request.get_json(silent=True) or {}
    token = body.get("token")
    env = body.get("env", "sandbox")
    if not token or env not in ("sandbox", "production"):
        return jsonify({"error": "token and env ('sandbox'|'production') are required"}), 400

    db = get_db()
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO device_push_token (token, env) VALUES (%s, %s) "
            "ON CONFLICT (token) DO UPDATE SET env = EXCLUDED.env",
            (token, env),
        )
    db.commit()
    return jsonify({"ok": True})


@alert_channel_bp.route("/heartbeat-sweep", methods=["POST"])
@require_api_key
def post_heartbeat_sweep():
    """Trigger the no-data sweep. In prod this is hit by an external periodic
    job (cron/systemd timer); there is no in-process scheduler."""
    db = get_db()
    try:
        raised = run_heartbeat_sweep(db, datetime.now(timezone.utc))
    except Exception as exc:
        logger.error("alert-channel heartbeat sweep failed: %s", type(exc).__name__)
        return jsonify({"error": "Internal server error"}), 500
    return jsonify({"raised": raised, "count": len(raised)})
