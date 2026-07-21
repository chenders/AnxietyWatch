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
``alert_event`` ledger. **Idempotency gates on delivery, not attempt**: a row is
written only after APNs accepts the push for at least one device, so a failed
delivery (no tokens, missing config, rejection, network error) stays retryable
rather than being silently marked "alerted" (design §5, own-failure-visible).

* **Backstop** — evaluated on every append over a *recent* (``ts_utc``-bounded)
  window, so a late catch-up upload of old samples can't fire it (the AS11
  stale-backlog lesson). A non-empty batch that lands entirely outside the
  window (stale/clock-skew) is logged, not silently ignored. Delegates the
  decision to the pure ``backstop`` evaluator; never re-implements on-device
  fusion.
* **Heartbeat** — a periodic sweep (``run_heartbeat_sweep``, cron-invoked in
  prod; there is no in-process scheduler) that raises "monitoring may have
  stopped" when a session's server-side ingest goes silent past
  ``HEARTBEAT_TIMEOUT_SECONDS``. Liveness keys on ``ingest_ts_utc`` (server
  clock — skew-proof). An append clears the session's heartbeat alert, so a
  later silence re-fires. NOTE: distinguishing a *cleanly disarmed* session from
  a *silently stalled* one needs the explicit arm/disarm signal that ships with
  sub-project C Task 5 (the iOS uploader); until then the sweep is effectively
  inert because nothing uploads. See ``HEARTBEAT_ACTIVE_LOOKBACK_SECONDS``.

Channel health (``GET /health``) surfaces whether APNs is configured, how many
device tokens are registered, and when an alert was last delivered — so the app
can detect a dark channel (design §5). Credentials come from env only; tokens,
keys, and JWTs are never logged (only kind + session id + counts).
"""
import hashlib
import json
import logging
import math
from collections import defaultdict
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

# APNs status that unambiguously means the device token is permanently dead and
# should be pruned: 410 Unregistered. NOT 400 — a 400 can be a server-side
# misconfig (bad topic/JWT/headers) that would return 400 for EVERY token and
# wipe the whole registry; distinguishing BadDeviceToken from other 400s needs
# the APNs `reason`, which apns.send() does not currently surface.
_DEAD_TOKEN_STATUSES = (410,)

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
# buffer never re-alerts on every sweep. Explicit disarm (Task 5) will replace
# this heuristic; the window is generous so a genuinely-armed phone that dies
# is still caught even if a sweep is delayed.
HEARTBEAT_ACTIVE_LOOKBACK_SECONDS = 12 * 3600.0

# Ship Time-Sensitive pushes until sub-project A's Critical Alerts entitlement
# lands (design §3 / §8); flip to True once it does.
PUSH_CRITICAL = False

# APNs device tokens are ~64 hex chars (32 bytes); cap generously so an
# authenticated client can't bloat the registry with an oversized token.
MAX_PUSH_TOKEN_LENGTH = 200

# Bound the /samples payload: a real live-upload batch is a handful of samples
# (a few KB). These cap parse/sort/DB work so an authenticated client can't
# force an oversized-payload DoS.
MAX_SAMPLES_PER_REQUEST = 1000
MAX_SAMPLES_REQUEST_BYTES = 1_000_000

# Session ids are app-generated (UUID-ish, ~36 chars); cap generously so a
# client can't bloat the buffer/indexes with an oversized id.
MAX_SESSION_ID_LENGTH = 128


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


def insert_buffer_sample(db, session_id, ts_utc, channel, value, source=None, ingest_ts_utc=None):
    """Append one sample to the per-session buffer; returns its id.

    ``ingest_ts_utc`` defaults to the server clock (NOW()); it is injectable so
    tests can backdate a session's last-heard-from time for the heartbeat sweep.
    (``append_samples`` batches its own inserts in one transaction; this helper
    is for single-sample inserts, primarily in tests.)
    """
    with db.cursor() as cur:
        if ingest_ts_utc is None:
            cur.execute(
                "INSERT INTO session_sample_buffer (session_id, ts_utc, channel, value, source) "
                "VALUES (%s, %s, %s, %s, %s) RETURNING id",
                (session_id, ts_utc, channel, value, source),
            )
        else:
            cur.execute(
                "INSERT INTO session_sample_buffer "
                "(session_id, ts_utc, channel, value, source, ingest_ts_utc) "
                "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                (session_id, ts_utc, channel, value, source, ingest_ts_utc),
            )
        sample_id = cur.fetchone()[0]
    db.commit()
    return sample_id


def _registered_tokens(db):
    with db.cursor() as cur:
        cur.execute("SELECT token, env FROM device_push_token")
        return cur.fetchall()


def push_alert(db, kind, session_id, *, critical=False):
    """Deliver one APNs push of ``kind`` to every registered device.

    Returns the number of devices APNs accepted (0 if none). Never raises: a
    missing token registry or missing APNs config is logged (own-failure-visible)
    and returns 0; a per-device send error is logged and skipped so one bad token
    can't shadow a working one; a token APNs reports permanently dead (410/400)
    is pruned. A return of 0 means "delivered to no one" — callers MUST NOT treat
    that as success.
    """
    tokens = _registered_tokens(db)
    if not tokens:
        logger.warning("alert-channel: %s raised for session=%s but no device push tokens registered",
                       kind, session_id)
        return 0
    try:
        config = apns.ApnsConfig.from_env()
    except apns.ApnsConfigError:
        logger.warning("alert-channel: %s raised for session=%s but APNs is not configured (env missing)",
                       kind, session_id)
        return 0

    payload = apns.build_payload(kind, critical=critical)
    sent = 0
    dead = []
    for token, env in tokens:
        try:
            result = apns.send(token, payload, critical=critical, config=config, use_sandbox=(env == "sandbox"))
        except Exception as exc:
            # A malformed key, network error, or missing HTTP/2 client must not
            # abort delivery to the remaining devices.
            logger.warning("alert-channel: APNs send failed for one device (%s)", type(exc).__name__)
            continue
        if result.ok:
            sent += 1
        elif result.status in _DEAD_TOKEN_STATUSES:
            dead.append(token)

    if dead:
        with db.cursor() as cur:
            cur.execute("DELETE FROM device_push_token WHERE token = ANY(%s)", (dead,))
        db.commit()
        logger.info("alert-channel: pruned %d dead device token(s)", len(dead))
    return sent


def _maybe_raise(db, session_id, kind, now, push):
    """Idempotently deliver + record ``kind`` for ``session_id``.

    Returns ``(delivered, sent)``. DELIVERY-GATED: the push is attempted BEFORE
    any ``alert_event`` row is written, so a crash mid-push (or a push that
    reaches no device) leaves no row — the alert stays retryable and ``/health``
    never reports an undelivered alert as delivered. The success write uses
    ``INSERT ... ON CONFLICT DO NOTHING`` against the UNIQUE(session_id, kind)
    index so a concurrent caller can't create a duplicate row. The only residue
    of a rare same-(session, kind) race is a duplicate push, which is acceptable
    for a redundant channel and far preferable to a claim-before-delivery scheme
    whose crash window could silently suppress a heartbeat.
    """
    with db.cursor() as cur:
        cur.execute("SELECT 1 FROM alert_event WHERE session_id = %s AND kind = %s LIMIT 1", (session_id, kind))
        if cur.fetchone():
            return (False, 0)  # already delivered for this event

    try:
        sent = push(db, kind, session_id, critical=PUSH_CRITICAL)
    except Exception as exc:  # pragma: no cover - push_alert already swallows
        logger.warning("alert-channel push raised for %s: %s", kind, type(exc).__name__)
        sent = 0

    if not sent:
        # Delivered to no device: record nothing, so the alert stays retryable
        # and /health surfaces the dark channel. Own failure must be visible.
        logger.warning("alert-channel: %s for session=%s not delivered to any device; will retry",
                       kind, session_id)
        return (False, 0)

    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO alert_event (session_id, kind, ts_utc) VALUES (%s, %s, %s) "
            "ON CONFLICT (session_id, kind) DO NOTHING",
            (session_id, kind, now),
        )
    db.commit()
    return (True, sent)


# --- Core logic (clock-injected, test-callable) -----------------------------


def append_samples(db, session_id, samples, now, push=None):
    """Buffer ``samples`` for ``session_id``, then evaluate the backstop.

    ``samples`` is an iterable of ``(ts_utc, channel, value)`` or
    ``(ts_utc, channel, value, source)`` (a 4th element tags the producing
    sensor; the backstop then evaluates each source independently). The batch insert
    and heartbeat-clear commit atomically, so a failure DURING the insert rolls
    back and the endpoint 500s before any commit (a retry is then clean). Once
    the batch is buffered, backstop evaluation + push are BEST-EFFORT: a failure
    there is logged and swallowed, not propagated, so it can't 500 the upload and
    make the client retry (which could duplicate buffer rows) — the next append
    re-evaluates. ``now`` is injected; ``push`` defaults to the real APNs sender.
    """
    if push is None:
        push = push_alert

    samples = list(samples)
    with db.cursor() as cur:
        if samples:
            # One round trip for the whole batch (live-upload is a high-write path).
            # A sample is (ts_utc, channel, value) or (ts_utc, channel, value, source).
            rows = [(session_id, s[0], s[1], s[2], s[3] if len(s) > 3 else None) for s in samples]
            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO session_sample_buffer (session_id, ts_utc, channel, value, source) VALUES %s",
                rows,
            )
            # Real data resumed -> the "monitoring stopped" alert no longer holds.
            # Gated on a non-empty batch so an empty POST (samples: []) can't
            # silence a pending heartbeat without an actual upload resuming.
            cur.execute("DELETE FROM alert_event WHERE session_id = %s AND kind = %s", (session_id, KIND_HEARTBEAT))
    db.commit()

    result = {
        "buffered": len(samples),
        "backstop_raised": False,
        "alert_delivered": False,
        "delivered_devices": 0,
        "last_ack_utc": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    # Samples are durably buffered above. The backstop evaluation + push are a
    # best-effort side effect: swallow any failure (logged) so it can't 500 the
    # upload and make the client retry a batch that is already stored.
    try:
        window_start = now - timedelta(seconds=ALERT_EVAL_WINDOW_SECONDS)
        with db.cursor() as cur:
            cur.execute(
                "SELECT ts_utc, channel, value, source FROM session_sample_buffer "
                "WHERE session_id = %s AND ts_utc >= %s AND ts_utc <= %s",
                (session_id, window_start, now),
            )
            rows = cur.fetchall()

        if samples and not rows:
            # Buffered samples but none fall in the recency window: the feed's
            # timestamps are stale or clock-skewed relative to server time.
            # Surface it rather than silently evaluating nothing.
            logger.warning(
                "alert-channel: session=%s buffered %d sample(s) but none within the %.0fs recency "
                "window (stale/clock-skew?)",
                session_id, len(samples), ALERT_EVAL_WINDOW_SECONDS,
            )

        # Evaluate the backstop PER SOURCE and raise if ANY source is
        # sustained-low: a normal reading from one concurrently-active SpO2
        # source must never reset (and thereby mask) a genuine sustained low on
        # another. Grouping here keeps the pure evaluator single-stream.
        by_source = defaultdict(list)
        for ts_utc, channel, value, source in rows:
            by_source[source].append(backstop.Sample(ts_utc, channel, float(value)))
        raised = any(backstop.evaluate(group, now).raised for group in by_source.values())
        result["backstop_raised"] = raised
        if raised:
            delivered, sent = _maybe_raise(db, session_id, KIND_BACKSTOP, now, push)
            result["alert_delivered"] = delivered
            result["delivered_devices"] = sent
    except Exception:
        # Clear any aborted transaction; the buffered batch is already committed.
        db.rollback()
        logger.exception("alert-channel backstop evaluation failed for session=%s", session_id)

    return result


def run_heartbeat_sweep(db, now, push=None):
    """Raise "monitoring may have stopped" for each armed session gone silent.

    A session is a candidate when its most recent server-side ingest is older
    than ``HEARTBEAT_TIMEOUT_SECONDS`` but still within
    ``HEARTBEAT_ACTIVE_LOOKBACK_SECONDS``. Idempotent per session (gated on
    delivery); cleared by the next append. Returns the list of session ids that
    delivered an alert on this sweep.
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
        delivered, _sent = _maybe_raise(db, session_id, KIND_HEARTBEAT, now, push)
        if delivered:
            raised.append(session_id)
    return raised


# --- HTTP endpoints ---------------------------------------------------------


def _parse_ts(value):
    dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if dt.tzinfo is None:
        # Naive input: assume UTC (the column is ts_utc).
        return dt.replace(tzinfo=timezone.utc)
    # Aware but possibly non-UTC: normalize to UTC so windowing/ordering can't be
    # skewed by a client that sends a non-UTC offset.
    return dt.astimezone(timezone.utc)


@alert_channel_bp.route("/samples", methods=["POST"])
@require_api_key
def post_samples():
    if request.content_length is not None and request.content_length > MAX_SAMPLES_REQUEST_BYTES:
        return jsonify({"error": "request body too large"}), 413

    # Bounded-chunk read from request.stream so a chunked-transfer upload (no
    # Content-Length) can't bypass the cap and force unbounded JSON parsing
    # (mirrors the /rr_archive pattern in server.py).
    chunks = []
    total = 0
    while True:
        chunk = request.stream.read(64 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_SAMPLES_REQUEST_BYTES:
            return jsonify({"error": "request body too large"}), 413
        chunks.append(chunk)
    try:
        body = json.loads(b"".join(chunks)) if chunks else {}
    except (ValueError, TypeError):
        return jsonify({"error": "invalid JSON body"}), 400
    if not isinstance(body, dict):
        return jsonify({"error": "invalid JSON body"}), 400

    session_id = body.get("session_id")
    session_id = session_id.strip() if isinstance(session_id, str) else None
    raw = body.get("samples")
    if not session_id or len(session_id) > MAX_SESSION_ID_LENGTH or not isinstance(raw, list):
        return jsonify({"error": "session_id (non-empty, <= %d chars) and samples[] are required"
                                 % MAX_SESSION_ID_LENGTH}), 400
    if len(raw) > MAX_SAMPLES_PER_REQUEST:
        return jsonify({"error": "too many samples in one request (max %d)" % MAX_SAMPLES_PER_REQUEST}), 413

    samples = []
    for item in raw:
        try:
            raw_source = item.get("source") if isinstance(item, dict) else None
            # Normalize blank/whitespace/non-string to None so a blank label
            # can't split one sensor's stream from the None group (which would
            # break a sustained-low run across the boundary).
            source = (raw_source.strip() or None) if isinstance(raw_source, str) else None
            # Reject non-finite values: json.loads accepts NaN/Infinity, and a
            # NaN would slip past the backstop's `value < FLOOR` check (NaN
            # comparisons are False) as a false "recovery" that resets a run.
            value = float(item["value"])
            if not math.isfinite(value):
                raise ValueError("value must be finite")
            samples.append((_parse_ts(item["ts_utc"]), str(item["channel"]), value, source))
        except (KeyError, TypeError, ValueError):
            return jsonify({"error": "each sample needs ts_utc, channel, and a finite value"}), 400

    db = get_db()
    try:
        result = append_samples(db, session_id, samples, datetime.now(timezone.utc))
    except Exception:
        logger.exception("alert-channel append failed for session=%s", session_id)
        return jsonify({"error": "Internal server error"}), 500
    return jsonify(result)


@alert_channel_bp.route("/push-token", methods=["POST"])
@require_api_key
def post_push_token():
    body = request.get_json(silent=True) or {}
    token = body.get("token")
    token = token.strip() if isinstance(token, str) else None
    env = body.get("env", "sandbox")
    if not token or len(token) > MAX_PUSH_TOKEN_LENGTH or env not in ("sandbox", "production"):
        return jsonify({"error": "token (non-empty, <= %d chars) and env ('sandbox'|'production') "
                                 "are required" % MAX_PUSH_TOKEN_LENGTH}), 400

    db = get_db()
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO device_push_token (token, env) VALUES (%s, %s) "
            "ON CONFLICT (token) DO UPDATE SET env = EXCLUDED.env",
            (token, env),
        )
    db.commit()
    return jsonify({"ok": True})


@alert_channel_bp.route("/disarm", methods=["POST"])
@require_api_key
def post_disarm():
    """Mark a monitoring session ended (the client calls this on disarm) so the
    no-data heartbeat doesn't fire a false "monitoring stopped" alert for a clean
    stop. Drops ONLY the session's buffered samples (removing it from heartbeat
    candidacy and bounding growth); the alert_event delivery ledger is preserved
    so /health keeps reporting the session's last delivered alert."""
    body = request.get_json(silent=True) or {}
    session_id = body.get("session_id")
    session_id = session_id.strip() if isinstance(session_id, str) else None
    if not session_id or len(session_id) > MAX_SESSION_ID_LENGTH:
        return jsonify({"error": "session_id (non-empty, <= %d chars) is required" % MAX_SESSION_ID_LENGTH}), 400

    db = get_db()
    with db.cursor() as cur:
        # Drop only the sample buffer: that removes the session from heartbeat
        # candidacy and bounds growth. Do NOT delete alert_event — those rows are
        # the delivered-alert ledger /health reports (MAX ts_utc); wiping them
        # would erase real delivery history for an ended session.
        cur.execute("DELETE FROM session_sample_buffer WHERE session_id = %s", (session_id,))
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
    except Exception:
        logger.exception("alert-channel heartbeat sweep failed")
        return jsonify({"error": "Internal server error"}), 500
    return jsonify({"raised": raised, "count": len(raised)})


@alert_channel_bp.route("/health", methods=["GET"])
@require_api_key
def get_health():
    """Channel-health surface (design §5, own-failure-visible): whether APNs is
    configured, how many device tokens are registered, and when an alert was
    last *delivered* (alert_event rows are written only on successful delivery),
    so the app can detect a dark channel. Never leaks secret material."""
    db = get_db()
    apns_configured = True
    try:
        apns.ApnsConfig.from_env()
    except apns.ApnsConfigError:
        apns_configured = False

    with db.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM device_push_token")
        token_count = cur.fetchone()[0]
        cur.execute("SELECT MAX(ts_utc) FROM alert_event")
        last_alert = cur.fetchone()[0]

    last_alert_iso = None
    if last_alert is not None:
        last_alert_iso = last_alert.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    return jsonify({
        "apns_configured": apns_configured,
        "registered_tokens": token_count,
        "last_delivered_alert_utc": last_alert_iso,
    })
