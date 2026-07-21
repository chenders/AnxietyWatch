import hashlib
import hmac
import json
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock

import pytest

from delta_oura_patch import fetch_and_persist_oura_data
from tests.test_server import app, _init_db  # noqa: F401, F811


class MockResponse:
    def __init__(self, json_data, status_code):
        self.json_data = json_data
        self.status_code = status_code

    def json(self):
        return self.json_data


@pytest.fixture
def mock_db_conn():
    conn = MagicMock()
    cursor = MagicMock()
    conn.cursor.return_value.__enter__.return_value = cursor
    return conn, cursor


def test_fetch_and_persist_oura_sleep(mock_db_conn):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'dummy_access',
        'refresh_token': 'dummy_refresh',
        'expires_at': datetime.now(timezone.utc) + timedelta(hours=1)
    }
    event_data = {'data_type': 'sleep'}

    http_client = MagicMock()
    http_client.get.return_value = MockResponse({
        'data': [{
            'day': '2024-01-01',
            'id': 'sleep_2024-01-01',
            'sleep_phase_5_min': '112233',
            'heart_rate_variability': {'5_min': [40, 45]},
            'respiratory_rate_5_min': [14.5, 14.6],
            'average_respiratory_rate': 14.55,
            'efficiency': 85,
            'latency': 300
        }]
    }, 200)

    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    http_client.get.assert_called_once_with(
        "https://api.ouraring.com/v2/usercollection/sleep",
        headers={"Authorization": "Bearer dummy_access"},
        params={}
    )
    cursor.execute.assert_called_once()
    sql_call = cursor.execute.call_args[0][0]
    assert "INSERT INTO oura_sleep" in sql_call


def test_fetch_and_persist_oura_daily_readiness(mock_db_conn):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'dummy_access',
        'refresh_token': 'dummy_refresh',
        'expires_at': datetime.now(timezone.utc) + timedelta(hours=1)
    }
    event_data = {'data_type': 'daily_readiness'}

    http_client = MagicMock()
    http_client.get.return_value = MockResponse({
        'data': [{
            'day': '2024-01-01',
            'id': 'readiness_123',
            'score': 88,
            'temperature_deviation': 0.1
        }]
    }, 200)

    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    assert cursor.execute.call_count == 2
    insert_call = cursor.execute.call_args_list[0][0][0]
    update_call = cursor.execute.call_args_list[1][0][0]
    assert "INSERT INTO oura_daily" in insert_call
    assert "UPDATE oura_daily SET readiness =" in update_call
    assert cursor.execute.call_args_list[1][0][1] == (88, 0.1, '2024-01-01')


def test_oura_token_refresh(mock_db_conn, monkeypatch):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'expired_access',
        'refresh_token': 'valid_refresh',
        'expires_at': datetime.now(timezone.utc) - timedelta(hours=1)
    }
    event_data = {'data_type': 'sleep'}

    http_client = MagicMock()
    # First post is refresh, second is get
    http_client.post.return_value = MockResponse({
        'access_token': 'new_access',
        'refresh_token': 'new_refresh',
        'expires_in': 3600
    }, 200)
    http_client.get.return_value = MockResponse({'data': []}, 200)

    # monkeypatch auto-restores env — no leak into later tests (e.g. the
    # webhook fail-closed test relies on OURA_CLIENT_SECRET being controllable).
    monkeypatch.setenv('OURA_CLIENT_ID', 'test_id')
    monkeypatch.setenv('OURA_CLIENT_SECRET', 'test_secret')

    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    http_client.post.assert_called_once()
    assert token_row['access_token'] == b'new_access'
    assert token_row['refresh_token'] == b'new_refresh'

    # DB update for token
    update_call = cursor.execute.call_args_list[0][0][0]
    assert "UPDATE oura_credentials" in update_call


def test_oura_refresh_keeps_old_refresh_token_when_not_rotated(mock_db_conn, monkeypatch):
    """Oura does not always return a new refresh_token on refresh; the old one
    must be preserved rather than crashing on a missing key."""
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'expired_access',
        'refresh_token': 'keep_me',
        'expires_at': datetime.now(timezone.utc) - timedelta(hours=1)
    }
    http_client = MagicMock()
    http_client.post.return_value = MockResponse({
        'access_token': 'new_access',
        # no refresh_token in the response
        'expires_in': 3600
    }, 200)
    http_client.get.return_value = MockResponse({'data': []}, 200)
    monkeypatch.setenv('OURA_CLIENT_ID', 'test_id')
    monkeypatch.setenv('OURA_CLIENT_SECRET', 'test_secret')

    res = fetch_and_persist_oura_data(token_row, {'data_type': 'sleep'}, conn, http_client)
    assert res is True
    assert token_row['access_token'] == b'new_access'
    assert token_row['refresh_token'] == b'keep_me'  # preserved, not KeyError'd


def test_oura_refresh_malformed_response_returns_false(mock_db_conn, monkeypatch):
    """A 200 refresh response with no access_token is malformed — return False
    (do not crash, do not proceed to fetch with a stale/empty token)."""
    conn, _ = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'expired_access',
        'refresh_token': 'valid_refresh',
        'expires_at': datetime.now(timezone.utc) - timedelta(hours=1)
    }
    http_client = MagicMock()
    http_client.post.return_value = MockResponse({'expires_in': 3600}, 200)  # no access_token
    monkeypatch.setenv('OURA_CLIENT_ID', 'test_id')
    monkeypatch.setenv('OURA_CLIENT_SECRET', 'test_secret')

    res = fetch_and_persist_oura_data(token_row, {'data_type': 'sleep'}, conn, http_client)
    assert res is False
    http_client.get.assert_not_called()  # never fetched with a bad token


def test_oura_refresh_http_error_returns_false(mock_db_conn, monkeypatch):
    """A non-200 from the refresh endpoint aborts before any fetch."""
    conn, _ = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'expired_access',
        'refresh_token': 'valid_refresh',
        'expires_at': datetime.now(timezone.utc) - timedelta(hours=1)
    }
    http_client = MagicMock()
    http_client.post.return_value = MockResponse({'error': 'invalid_grant'}, 400)
    monkeypatch.setenv('OURA_CLIENT_ID', 'test_id')
    monkeypatch.setenv('OURA_CLIENT_SECRET', 'test_secret')

    res = fetch_and_persist_oura_data(token_row, {'data_type': 'sleep'}, conn, http_client)
    assert res is False
    http_client.get.assert_not_called()


# --- webhook route: signature verification fails closed --------------------


def _sign(secret, body_bytes):
    return hmac.new(secret.encode("utf-8"), body_bytes, hashlib.sha256).hexdigest()


def test_webhook_challenge_is_echoed(app):  # noqa: F811
    """The subscription-verification challenge is echoed before any signature
    check (it arrives unsigned)."""
    with app.test_client() as client:
        resp = client.get("/webhooks/oura?challenge=abc123")
    assert resp.status_code == 200
    assert resp.get_data(as_text=True) == "abc123"


def test_webhook_fail_closed_when_secret_unset(app, monkeypatch):  # noqa: F811
    """An unconfigured signing secret must REJECT (503), never verify a forged
    call against a guessable default."""
    monkeypatch.delenv("OURA_CLIENT_SECRET", raising=False)
    with app.test_client() as client:
        resp = client.post(
            "/webhooks/oura",
            data=json.dumps({"data_type": "sleep"}),
            headers={"x-oura-signature": "anything", "Content-Type": "application/json"},
        )
    assert resp.status_code == 503


def test_webhook_rejects_missing_signature(app, monkeypatch):  # noqa: F811
    monkeypatch.setenv("OURA_CLIENT_SECRET", "s3cret")
    with app.test_client() as client:
        resp = client.post(
            "/webhooks/oura",
            data=json.dumps({"data_type": "sleep"}),
            headers={"Content-Type": "application/json"},
        )
    assert resp.status_code == 401


def test_webhook_rejects_invalid_signature(app, monkeypatch):  # noqa: F811
    monkeypatch.setenv("OURA_CLIENT_SECRET", "s3cret")
    with app.test_client() as client:
        resp = client.post(
            "/webhooks/oura",
            data=json.dumps({"data_type": "sleep"}),
            headers={"x-oura-signature": "deadbeef", "Content-Type": "application/json"},
        )
    assert resp.status_code == 401


def test_webhook_accepts_valid_signature_without_credentials(app, monkeypatch):  # noqa: F811
    """A correctly-signed webhook is accepted (200) even when no credentials are
    stored yet — it just logs and no-ops rather than erroring."""
    monkeypatch.setenv("OURA_CLIENT_SECRET", "s3cret")
    body = json.dumps({"data_type": "sleep"}).encode("utf-8")
    with app.test_client() as client:
        resp = client.post(
            "/webhooks/oura",
            data=body,
            headers={"x-oura-signature": _sign("s3cret", body), "Content-Type": "application/json"},
        )
    assert resp.status_code == 200
