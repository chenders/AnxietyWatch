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

import apns
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


# --- delivery-gated idempotency + failure visibility ----------------------


class _FailingPush:
    """Push seam that never reaches a device (delivered to no one -> returns 0)."""

    def __init__(self):
        self.calls = 0

    def __call__(self, db, kind, session_id, *, critical=False):
        self.calls += 1
        return 0


def test_failed_delivery_is_not_recorded_and_retries(app, _clean_tables):  # noqa: F811
    """A raise that delivers to no device must NOT write the alert_event ledger
    row, so it stays retryable on the next append rather than being silently
    marked 'alerted' (the core own-failure-visible invariant)."""
    push = _FailingPush()
    with app.app_context():
        db = app.get_db()
        append_samples(db, "sess-fail", _low_run("sess-fail", 0, SUSTAIN),
                       REF + timedelta(seconds=SUSTAIN), push=push)
        more = [(REF + timedelta(seconds=SUSTAIN + 1), backstop.SPO2_CHANNEL, LOW)]
        append_samples(db, "sess-fail", more, REF + timedelta(seconds=SUSTAIN + 1), push=push)

        # Pushed on BOTH appends (undelivered -> retried), and no ledger row exists.
        assert push.calls == 2
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM alert_event WHERE session_id = %s AND kind = %s",
                        ("sess-fail", alert_channel.KIND_BACKSTOP))
            assert cur.fetchone()[0] == 0


def test_dead_token_pruned_on_apns_410(app, _clean_tables, monkeypatch):  # noqa: F811
    """push_alert prunes a token APNs reports permanently dead (410) and returns
    0 (delivered to no one)."""
    monkeypatch.setenv("APNS_AUTH_KEY", "fictional-not-a-real-key")
    monkeypatch.setenv("APNS_KEY_ID", "KEY1234567")
    monkeypatch.setenv("APNS_TEAM_ID", "TEAM123456")
    monkeypatch.setenv("APNS_TOPIC", "org.example.anxietywatch.fictional")
    monkeypatch.setenv("APNS_ENV", "sandbox")
    monkeypatch.setattr(
        apns, "send",
        lambda *a, **k: apns.ApnsResult(ok=False, status=410, apns_id=None),
    )

    with app.app_context():
        db = app.get_db()
        with db.cursor() as cur:
            cur.execute("INSERT INTO device_push_token (token, env) VALUES (%s, %s)",
                        ("dead-fictional-token", "sandbox"))
        db.commit()

        sent = alert_channel.push_alert(db, alert_channel.KIND_BACKSTOP, "sess-x")
        assert sent == 0
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM device_push_token WHERE token = %s",
                        ("dead-fictional-token",))
            assert cur.fetchone()[0] == 0


# --- channel-health surface -----------------------------------------------


def test_health_surfaces_dark_channel(app, _clean_tables):  # noqa: F811
    """With no APNs env and no tokens, /health reports the channel as dark so
    the app can detect it (never reads as all-clear)."""
    with app.test_client() as client:
        data = client.get("/api/alert-channel/health", headers=auth_header()).get_json()
        assert data["apns_configured"] is False
        assert data["registered_tokens"] == 0
        assert data["last_delivered_alert_utc"] is None

        client.post("/api/alert-channel/push-token", headers=auth_header(),
                    json={"token": "fictional-device-token", "env": "sandbox"})
        data = client.get("/api/alert-channel/health", headers=auth_header()).get_json()
        assert data["registered_tokens"] == 1


def test_health_requires_auth(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        assert client.get("/api/alert-channel/health").status_code == 401


def test_empty_batch_does_not_clear_heartbeat(app, _clean_tables):  # noqa: F811
    """An empty samples POST must NOT silence a pending heartbeat — only an
    actual data upload resuming clears it."""
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=600)
        insert_buffer_sample(db, "sess-empty", REF, "SPO2", NORMAL)
        _silence(db, "sess-empty", now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS + 30))
        run_heartbeat_sweep(db, now, push=push)
        assert push.kinds() == [alert_channel.KIND_HEARTBEAT]

        append_samples(db, "sess-empty", [], now + timedelta(seconds=5), push=push)
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM alert_event WHERE session_id = %s AND kind = %s",
                        ("sess-empty", alert_channel.KIND_HEARTBEAT))
            assert cur.fetchone()[0] == 1  # heartbeat still pending, not cleared by empty POST


def test_parse_ts_normalizes_to_utc():
    """A non-UTC offset is normalized to UTC (same instant); a naive value is
    assumed UTC — so windowing/ordering can't be skewed by the client's offset."""
    assert alert_channel._parse_ts("2026-07-20T03:00:00-07:00") == \
        datetime(2026, 7, 20, 10, 0, 0, tzinfo=timezone.utc)
    assert alert_channel._parse_ts("2026-07-20T03:00:00") == \
        datetime(2026, 7, 20, 3, 0, 0, tzinfo=timezone.utc)


def test_future_dated_batch_does_not_raise(app, _clean_tables):  # noqa: F811
    """A sustained-low run timestamped AFTER now (client clock skew or malicious
    input) is excluded from the backstop window, so it can't false-raise."""
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=SUSTAIN)
        future = [(now + timedelta(seconds=t), backstop.SPO2_CHANNEL, LOW)
                  for t in range(1, SUSTAIN + 2)]
        append_samples(db, "sess-future", future, now, push=push)
    assert push.calls == []


def test_push_token_rejects_oversized_token(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        resp = client.post("/api/alert-channel/push-token", headers=auth_header(),
                           json={"token": "x" * 500, "env": "sandbox"})
        assert resp.status_code == 400
    with app.app_context():
        db = app.get_db()
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM device_push_token")
            assert cur.fetchone()[0] == 0


def test_samples_rejects_oversized_list(app, _clean_tables):  # noqa: F811
    big = [{"ts_utc": REF.isoformat(), "channel": "SPO2", "value": NORMAL}
           for _ in range(alert_channel.MAX_SAMPLES_PER_REQUEST + 1)]
    with app.test_client() as client:
        resp = client.post("/api/alert-channel/samples", headers=auth_header(),
                           json={"session_id": "sess-big", "samples": big})
        assert resp.status_code == 413


def test_samples_rejects_oversized_session_id(app, _clean_tables):  # noqa: F811
    with app.test_client() as client:
        resp = client.post("/api/alert-channel/samples", headers=auth_header(),
                           json={"session_id": "s" * (alert_channel.MAX_SESSION_ID_LENGTH + 1),
                                 "samples": []})
        assert resp.status_code == 400


def test_samples_rejects_invalid_json(app, _clean_tables):  # noqa: F811
    """The bounded-read parse path rejects a malformed body with 400."""
    with app.test_client() as client:
        resp = client.post("/api/alert-channel/samples", headers=auth_header(),
                           data="not json", content_type="application/json")
        assert resp.status_code == 400


def test_disarm_clears_session_and_prevents_heartbeat(app, _clean_tables):  # noqa: F811
    """Disarm drops the session's buffer + alerts, so a subsequent sweep finds
    no candidate and the no-data heartbeat can't false-fire for a clean stop."""
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=600)
        insert_buffer_sample(db, "sess-disarm", REF, "SPO2", NORMAL)
        _silence(db, "sess-disarm", now - timedelta(seconds=HEARTBEAT_TIMEOUT_SECONDS + 30))

    with app.test_client() as client:
        resp = client.post("/api/alert-channel/disarm", headers=auth_header(),
                           json={"session_id": "sess-disarm"})
        assert resp.status_code == 200

    with app.app_context():
        db = app.get_db()
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM session_sample_buffer WHERE session_id = %s", ("sess-disarm",))
            assert cur.fetchone()[0] == 0
        assert run_heartbeat_sweep(db, now, push=push) == []
    assert push.calls == []


def test_backstop_evaluated_per_source_not_masked(app, _clean_tables):  # noqa: F811
    """Two concurrent SpO2 sources: one sustained-low, the other interleaving
    NORMAL readings at the same timestamps. Per-source evaluation must still
    raise — a merged single stream would let the normal source reset the low
    source's run and never fire (the concurrent-source masking hazard)."""
    push = _Recorder()
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=SUSTAIN)
        samples = []
        for t in range(0, SUSTAIN + 1):
            samples.append((REF + timedelta(seconds=t), backstop.SPO2_CHANNEL, LOW, "as11"))
            samples.append((REF + timedelta(seconds=t), backstop.SPO2_CHANNEL, NORMAL, "emay"))
        append_samples(db, "sess-multi", samples, now, push=push)
    assert push.kinds() == [alert_channel.KIND_BACKSTOP]


def test_eval_failure_does_not_fail_the_upload(app, _clean_tables, monkeypatch):  # noqa: F811
    """If backstop evaluation raises after the batch is buffered, the failure is
    swallowed (logged) — the samples stay buffered and append returns normally,
    so the upload doesn't 500 and the client doesn't retry-duplicate."""
    def boom(*a, **k):
        raise RuntimeError("eval boom")
    monkeypatch.setattr(alert_channel.backstop, "evaluate", boom)
    with app.app_context():
        db = app.get_db()
        now = REF + timedelta(seconds=SUSTAIN)
        result = append_samples(db, "sess-eval", _low_run("sess-eval", 0, SUSTAIN), now, push=_Recorder())
        assert result["buffered"] == SUSTAIN + 1
        assert result["backstop_raised"] is False
        with db.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM session_sample_buffer WHERE session_id = %s", ("sess-eval",))
            assert cur.fetchone()[0] == SUSTAIN + 1
