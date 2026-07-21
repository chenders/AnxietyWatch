"""Tests for the redundant alert-channel endpoints + wiring (``api/alert_channel.py``).

Sub-project C Task 4. Covers: the authed append endpoint buffers samples; a
sustained low run raises exactly one backstop push (idempotent per event); a
brief dip does not; a stale (old-``ts_utc``) batch does not; the heartbeat sweep
raises once when a session's server-side ingest goes silent past the timeout and
re-fires after uploads resume; and push-token registration dedups.

Pushes are captured by an injected recorder — no APNs network in CI. The clock
is injected everywhere a decision depends on it (no wall-clock in assertions).
"""
from datetime import datetime, timedelta, timezone

import backstop
from api import alert_channel
from api.alert_channel import (
    ALERT_EVAL_WINDOW_SECONDS,
    HEARTBEAT_TIMEOUT_SECONDS,
    append_samples,
    insert_buffer_sample,
    run_heartbeat_sweep,
)
from tests.test_server import app, _clean_tables, _init_db, auth_header  # noqa: F401, F811

REF = datetime(2026, 7, 20, 3, 0, 0, tzinfo=timezone.utc)
LOW = backstop.SPO2_FLOOR - 5.0       # clearly below the fixed floor
NORMAL = backstop.SPO2_FLOOR + 10.0   # clearly above it
SUSTAIN = int(backstop.SUSTAIN_SECONDS)


class _Recorder:
    """Injectable push seam: records (kind, session_id, critical) per call."""

    def __init__(self):
        self.calls = []

    def __call__(self, db, kind, session_id, *, critical=False):
        self.calls.append((kind, session_id, critical))
        return 1

    def kinds(self):
        return [c[0] for c in self.calls]


def _low_run(session_id, start_s, end_s, step_s=1):
    """A gap-free below-floor SpO2 run, ts_utc relative to REF."""
    return [
        (REF + timedelta(seconds=t), backstop.SPO2_CHANNEL, LOW)
        for t in range(start_s, end_s + 1, step_s)
    ]


# --- append endpoint: buffering + auth ------------------------------------


def test_append_endpoint_buffers_samples(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        resp = client.post(
            "/api/alert-channel/samples",
            headers=auth_header(),
            json={
                "session_id": "sess-1",
                "samples": [
                    {"ts_utc": REF.isoformat(), "channel": "SPO2", "value": NORMAL},
                    {"ts_utc": (REF + timedelta(seconds=1)).isoformat(),
                     "channel": "SPO2", "value": NORMAL},
                ],
            },
        )
        assert resp.status_code == 200, resp.get_data(as_text=True)
        assert resp.get_json()["buffered"] == 2

    with app.app_context():
        db = app.get_db()
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM session_sample_buffer WHERE session_id = %s", ("sess-1",))
            assert cur.fetchone()[0] == 2


def test_append_endpoint_requires_auth(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        resp = client.post("/api/alert-channel/samples", json={"session_id": "x", "samples": []})
        assert resp.status_code == 401


# --- backstop on append: idempotent single push ---------------------------


def test_sustained_low_raises_exactly_one_push(app, _clean_tables):  # noqa: F811
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=SUSTAIN)
        append_samples(db, "sess-low", _low_run("sess-low", 0, SUSTAIN), now, push=push)
        # A second append while still sustained-low must NOT re-push (idempotent).
        more = [(REF + timedelta(seconds=SUSTAIN + 1), backstop.SPO2_CHANNEL, LOW)]
        append_samples(db, "sess-low", more, REF + timedelta(seconds=SUSTAIN + 1), push=push)

    assert push.kinds() == [alert_channel.KIND_BACKSTOP]


def test_brief_dip_does_not_raise(app, _clean_tables):  # noqa: F811
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        samples = _low_run("sess-dip", 0, SUSTAIN // 3) + [
            (REF + timedelta(seconds=SUSTAIN // 3 + 1), backstop.SPO2_CHANNEL, NORMAL)
        ]
        append_samples(db, "sess-dip", samples, REF + timedelta(seconds=SUSTAIN), push=push)
    assert push.calls == []


def test_stale_batch_does_not_raise(app, _clean_tables):  # noqa: F811
    """A sustained-low batch whose ts_utc is older than the eval window is
    excluded, so a late catch-up upload of old data can't fire the backstop
    (the AS11 stale-backlog lesson, applied to the buffer)."""
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        # A full sustained low run, but shifted far into the past relative to now.
        old = [
            (REF + timedelta(seconds=t), backstop.SPO2_CHANNEL, LOW)
            for t in range(0, SUSTAIN + 1)
        ]
        now = REF + timedelta(seconds=SUSTAIN + ALERT_EVAL_WINDOW_SECONDS + 60)
        append_samples(db, "sess-stale", old, now, push=push)
    assert push.calls == []


# --- heartbeat sweep: fire once, clear on resume --------------------------


def _silence(db, session_id, last_ingest):
    """Force the session's most recent server-ingest time to ``last_ingest``."""
    with db.cursor() as cur:
        cur.execute(
            "UPDATE session_sample_buffer SET ingest_ts_utc = %s WHERE session_id = %s",
            (last_ingest, session_id),
        )
    db.commit()


def test_heartbeat_fires_once_when_silent(app, _clean_tables):  # noqa: F811
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=600)
        insert_buffer_sample(db, "sess-hb", REF, "SPO2", NORMAL)
        _silence(db, "sess-hb", now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS + 30))

        run_heartbeat_sweep(db, now, push=push)
        run_heartbeat_sweep(db, now + timedelta(seconds=5), push=push)  # idempotent

    assert push.kinds() == [alert_channel.KIND_HEARTBEAT]


def test_heartbeat_not_fired_within_timeout(app, _clean_tables):  # noqa: F811
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=600)
        insert_buffer_sample(db, "sess-fresh", REF, "SPO2", NORMAL)
        _silence(db, "sess-fresh", now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS - 10))
        run_heartbeat_sweep(db, now, push=push)
    assert push.calls == []


def test_heartbeat_clears_on_resume_then_refires(app, _clean_tables):  # noqa: F811
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=600)
        insert_buffer_sample(db, "sess-rs", REF, "SPO2", NORMAL)
        _silence(db, "sess-rs", now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS + 30))
        run_heartbeat_sweep(db, now, push=push)          # fires
        assert push.kinds() == [alert_channel.KIND_HEARTBEAT]

        # Uploads resume -> the heartbeat alert clears.
        resume = now + timedelta(seconds=10)
        append_samples(db, "sess-rs", [(resume, "SPO2", NORMAL)], resume, push=push)

        # Then it goes silent again -> a later sweep must fire a fresh heartbeat.
        later = resume + timedelta(seconds=600)
        _silence(db, "sess-rs", later - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS + 30))
        run_heartbeat_sweep(db, later, push=push)

    assert push.kinds() == [alert_channel.KIND_HEARTBEAT, alert_channel.KIND_HEARTBEAT]


# --- push-token registration ----------------------------------------------


def test_push_token_registration_dedups(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        for _ in range(2):
            resp = client.post(
                "/api/alert-channel/push-token",
                headers=auth_header(),
                json={"token": "fictional-device-token", "env": "sandbox"},
            )
            assert resp.status_code == 200, resp.get_data(as_text=True)

    with app.app_context():
        db = app.get_db()
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM device_push_token WHERE token = %s",
                        ("fictional-device-token",))
            assert cur.fetchone()[0] == 1
