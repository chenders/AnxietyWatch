"""Tests for the myAir API client (synchronous requests-based)."""

from unittest.mock import patch, MagicMock

import pytest

from resmed_client import MyAirClient, MyAirAuthError, MyAirAPIError, _normalize_record


# ---------------------------------------------------------------------------
# _normalize_record tests
# ---------------------------------------------------------------------------

def test_normalize_valid_record():
    raw = {"startDate": "2025-08-15", "totalUsage": 420, "ahi": 2.3, "leakPercentile": 12.5}
    result = _normalize_record(raw)
    assert result["date"] == "2025-08-15"
    assert result["ahi"] == 2.3
    assert result["total_usage_minutes"] == 420
    assert result["leak_percentile"] == 12.5
    assert result["mean_pressure"] is None


def test_normalize_missing_required():
    assert _normalize_record({"startDate": "2025-08-15", "ahi": 2.3}) is None


def test_normalize_non_dict():
    assert _normalize_record("not a dict") is None


def test_normalize_bad_value():
    assert _normalize_record({"startDate": "x", "ahi": "bad", "totalUsage": 420}) is None


def test_normalize_optional_missing():
    raw = {"startDate": "2025-08-15", "ahi": 1.0, "totalUsage": 300}
    result = _normalize_record(raw)
    assert result is not None
    assert result["leak_percentile"] is None


# ---------------------------------------------------------------------------
# MyAirClient tests (mocked HTTP)
# ---------------------------------------------------------------------------

def _mock_auth_responses():
    """Return mock responses for the 3-step auth flow."""
    authn = MagicMock()
    authn.json.return_value = {"status": "SUCCESS", "sessionToken": "fake-token"}

    authorize = MagicMock()
    authorize.status_code = 200
    authorize.text = "data.code = 'fake-auth-code'"
    authorize.headers = {}

    token = MagicMock()
    token.status_code = 200
    token.json.return_value = {"access_token": "fake-access-token", "token_type": "Bearer"}

    return authn, authorize, token


@patch("resmed_client.requests")
@patch.dict("os.environ", {"GRAPHQL_API_KEY": "test-key"})
def test_fetch_sessions_returns_list(mock_requests):
    authn, authorize, token_resp = _mock_auth_responses()

    graphql = MagicMock()
    graphql.status_code = 200
    graphql.json.return_value = {
        "data": {"getPatientWrapper": {"sleepRecords": {"items": [
            {"startDate": "2025-08-15", "ahi": 2.3, "totalUsage": 420, "leakPercentile": 12.5},
            {"startDate": "2025-08-14", "ahi": 1.1, "totalUsage": 390},
        ]}}}
    }

    mock_requests.post.side_effect = [authn, token_resp, graphql]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    result = client.fetch_sessions(days=7)

    assert len(result) == 2
    assert result[0]["date"] == "2025-08-15"
    assert result[0]["ahi"] == 2.3
    assert result[1]["total_usage_minutes"] == 390

    # Verify authorize uses allow_redirects=False
    get_call = mock_requests.get.call_args
    assert get_call.kwargs.get("allow_redirects") is False


@patch("resmed_client.requests")
def test_auth_failure_raises(mock_requests):
    authn = MagicMock()
    authn.json.return_value = {"status": "UNAUTHENTICATED", "errorSummary": "Bad credentials"}
    authn.raise_for_status = MagicMock()
    mock_requests.post.return_value = authn

    client = MyAirClient(username="bad@example.com", password="wrong")
    with pytest.raises(MyAirAuthError, match="Bad credentials"):
        client.fetch_sessions()


@patch("resmed_client.requests")
@patch.dict("os.environ", {"GRAPHQL_API_KEY": "test-key"})
def test_empty_records(mock_requests):
    authn, authorize, token_resp = _mock_auth_responses()

    graphql = MagicMock()
    graphql.status_code = 200
    graphql.json.return_value = {
        "data": {"getPatientWrapper": {"sleepRecords": {"items": []}}}
    }

    mock_requests.post.side_effect = [authn, token_resp, graphql]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    assert client.fetch_sessions(days=7) == []


@patch("resmed_client.requests")
@patch.dict("os.environ", {"GRAPHQL_API_KEY": "test-key"})
def test_graphql_error_raises(mock_requests):
    authn, authorize, token_resp = _mock_auth_responses()

    graphql = MagicMock()
    graphql.status_code = 200
    graphql.json.return_value = {"errors": [{"message": "Unauthorized"}]}

    mock_requests.post.side_effect = [authn, token_resp, graphql]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    with pytest.raises(MyAirAPIError, match="GraphQL errors"):
        client.fetch_sessions()


@patch("resmed_client.requests")
def test_network_error_wrapped(mock_requests):
    import requests as real_requests
    mock_requests.post.side_effect = real_requests.ConnectionError("DNS failed")

    client = MyAirClient(username="user@example.com", password="secret")
    with pytest.raises(MyAirAuthError):
        client.fetch_sessions()


@patch("resmed_client.requests")
def test_non_json_token_response(mock_requests):
    authn, authorize, _ = _mock_auth_responses()

    bad_token = MagicMock()
    bad_token.status_code = 502
    bad_token.json.side_effect = ValueError("No JSON")

    mock_requests.post.side_effect = [authn, bad_token]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    with pytest.raises(MyAirAuthError, match="non-JSON"):
        client.fetch_sessions()


@patch("resmed_client.requests")
@patch.dict("os.environ", {"GRAPHQL_API_KEY": "test-key"})
def test_auth_code_from_location_header(mock_requests):
    """Verify fallback: extract auth code from 302 Location header."""
    authn = MagicMock()
    authn.json.return_value = {"status": "SUCCESS", "sessionToken": "token"}
    authn.raise_for_status = MagicMock()

    # Authorize returns 302 with code in Location, no HTML body
    authorize = MagicMock()
    authorize.status_code = 302
    authorize.text = "<html>redirecting...</html>"
    authorize.headers = {"Location": "https://myair.resmed.com?code=redirect-auth-code&state=xyz"}

    token_resp = MagicMock()
    token_resp.status_code = 200
    token_resp.json.return_value = {"access_token": "token", "token_type": "Bearer"}

    graphql = MagicMock()
    graphql.status_code = 200
    graphql.json.return_value = {
        "data": {"getPatientWrapper": {"sleepRecords": {"items": [
            {"startDate": "2025-08-15", "ahi": 2.0, "totalUsage": 400},
        ]}}}
    }

    mock_requests.post.side_effect = [authn, token_resp, graphql]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    result = client.fetch_sessions(days=7)
    assert len(result) == 1
    assert result[0]["ahi"] == 2.0


@patch("resmed_client.requests")
def test_missing_graphql_api_key(mock_requests):
    """Verify error when GRAPHQL_API_KEY is not set."""
    authn, authorize, token_resp = _mock_auth_responses()
    mock_requests.post.side_effect = [authn, token_resp]
    mock_requests.get.return_value = authorize

    client = MyAirClient(username="user@example.com", password="secret")
    with pytest.raises(MyAirAPIError, match="GRAPHQL_API_KEY"):
        client.fetch_sessions()
