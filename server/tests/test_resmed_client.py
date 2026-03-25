"""Tests for the myAir API client.

Uses unittest.mock to mock HTTP responses for the Okta OAuth flow
and AppSync GraphQL queries.
"""

import pytest
from unittest.mock import AsyncMock, patch

from resmed_client import MyAirClient, MyAirAuthError, MyAirAPIError, _normalize_record


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_sleep_record(**overrides):
    base = {
        "startDate": "2025-08-15",
        "totalUsage": 420,
        "sleepScore": 80,
        "ahi": 2.3,
        "leakPercentile": 12.5,
        "maskPairCount": 1,
        "__typename": "SleepRecord",
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# _normalize_record tests (pure, no async)
# ---------------------------------------------------------------------------

def test_normalize_valid_record():
    result = _normalize_record(_make_sleep_record())
    assert result["date"] == "2025-08-15"
    assert result["ahi"] == 2.3
    assert result["total_usage_minutes"] == 420
    assert result["leak_percentile"] == 12.5
    assert result["mean_pressure"] is None


def test_normalize_missing_required_field():
    record = {"startDate": "2025-08-15", "ahi": 2.3}  # missing totalUsage
    assert _normalize_record(record) is None


def test_normalize_non_dict():
    assert _normalize_record("not a dict") is None


def test_normalize_bad_ahi_value():
    record = _make_sleep_record(ahi="not-a-number")
    assert _normalize_record(record) is None


def test_normalize_missing_optional_fields():
    record = {"startDate": "2025-08-15", "ahi": 1.0, "totalUsage": 300}
    result = _normalize_record(record)
    assert result is not None
    assert result["leak_percentile"] is None


# ---------------------------------------------------------------------------
# MyAirClient tests (async, mocked HTTP)
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_session():
    """Create a mock aiohttp.ClientSession with configurable responses."""
    session = AsyncMock()

    # Step 1: Okta authn
    authn_resp = AsyncMock()
    authn_resp.json = AsyncMock(return_value={
        "status": "SUCCESS",
        "sessionToken": "fake-session-token",
    })

    # Step 2: Authorize (returns HTML with auth code)
    authorize_resp = AsyncMock()
    authorize_resp.text = AsyncMock(return_value="data.code = 'fake-auth-code'")

    # Step 3: Token exchange
    token_resp = AsyncMock()
    token_resp.json = AsyncMock(return_value={
        "access_token": "fake-access-token",
        "token_type": "Bearer",
    })

    # Step 4: GraphQL query
    graphql_resp = AsyncMock()
    graphql_resp.status = 200
    graphql_resp.json = AsyncMock(return_value={
        "data": {
            "getPatientWrapper": {
                "sleepRecords": {
                    "items": [
                        _make_sleep_record(startDate="2025-08-15", ahi=2.3),
                        _make_sleep_record(startDate="2025-08-14", ahi=1.1, totalUsage=390),
                    ]
                }
            }
        }
    })

    session.post = AsyncMock(side_effect=[authn_resp, token_resp, graphql_resp])
    session.get = AsyncMock(return_value=authorize_resp)

    return session


@pytest.mark.asyncio
async def test_fetch_sessions_returns_list(mock_session):
    with patch("resmed_client.aiohttp.ClientSession") as mock_cls:
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_session)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        client = MyAirClient(username="user@example.com", password="secret")
        result = await client.fetch_sessions(days=7)

    assert len(result) == 2
    assert result[0]["date"] == "2025-08-15"
    assert result[0]["ahi"] == 2.3
    assert result[1]["total_usage_minutes"] == 390


@pytest.mark.asyncio
async def test_auth_failure_raises():
    session = AsyncMock()
    authn_resp = AsyncMock()
    authn_resp.json = AsyncMock(return_value={
        "status": "UNAUTHENTICATED",
        "errorSummary": "Authentication failed",
    })
    session.post = AsyncMock(return_value=authn_resp)

    with patch("resmed_client.aiohttp.ClientSession") as mock_cls:
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=session)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        client = MyAirClient(username="bad@example.com", password="wrong")
        with pytest.raises(MyAirAuthError, match="Authentication failed"):
            await client.fetch_sessions()


@pytest.mark.asyncio
async def test_empty_records(mock_session):
    empty_graphql_resp = AsyncMock()
    empty_graphql_resp.status = 200
    empty_graphql_resp.json = AsyncMock(return_value={
        "data": {"getPatientWrapper": {"sleepRecords": {"items": []}}}
    })
    # Rebuild the post side_effect with empty graphql response
    authn_resp = AsyncMock()
    authn_resp.json = AsyncMock(return_value={
        "status": "SUCCESS", "sessionToken": "fake-session-token",
    })
    token_resp = AsyncMock()
    token_resp.json = AsyncMock(return_value={
        "access_token": "fake-access-token", "token_type": "Bearer",
    })
    mock_session.post = AsyncMock(side_effect=[authn_resp, token_resp, empty_graphql_resp])

    with patch("resmed_client.aiohttp.ClientSession") as mock_cls:
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_session)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        client = MyAirClient(username="user@example.com", password="secret")
        result = await client.fetch_sessions(days=7)

    assert result == []


@pytest.mark.asyncio
async def test_graphql_error_raises():
    session = AsyncMock()
    authn_resp = AsyncMock()
    authn_resp.json = AsyncMock(return_value={
        "status": "SUCCESS", "sessionToken": "token",
    })
    authorize_resp = AsyncMock()
    authorize_resp.text = AsyncMock(return_value="data.code = 'code'")
    token_resp = AsyncMock()
    token_resp.json = AsyncMock(return_value={"access_token": "token"})
    graphql_resp = AsyncMock()
    graphql_resp.status = 200
    graphql_resp.json = AsyncMock(return_value={
        "errors": [{"message": "Unauthorized"}]
    })

    session.post = AsyncMock(side_effect=[authn_resp, token_resp, graphql_resp])
    session.get = AsyncMock(return_value=authorize_resp)

    with patch("resmed_client.aiohttp.ClientSession") as mock_cls:
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=session)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        client = MyAirClient(username="user@example.com", password="secret")
        with pytest.raises(MyAirAPIError, match="GraphQL errors"):
            await client.fetch_sessions()
