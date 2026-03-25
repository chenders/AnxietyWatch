"""Tests for the myAir API client wrapper.

Uses unittest.mock throughout since the myair-py package may not be installed
in the test environment, and we want to test our wrapper logic in isolation.
"""

import importlib
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers to build mock sleep records matching the myair-py SleepRecord shape
# ---------------------------------------------------------------------------


def _make_sleep_record(**overrides):
    """Return a dict shaped like a myair-py SleepRecord TypedDict."""
    base = {
        "startDate": "2025-08-15",
        "totalUsage": 420,
        "sleepScore": 80,
        "usageScore": 90,
        "ahiScore": 95,
        "maskScore": 85,
        "leakScore": 88,
        "ahi": 2.3,
        "maskPairCount": 1,
        "leakPercentile": 12.5,
        "sleepRecordPatientId": "patient-123",
        "__typename": "SleepRecord",
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# Fixture: ensure resmed_client module is importable
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _ensure_module_importable():
    """Make sure the resmed_client module can be imported.

    The real myair_py dependency may not be installed, but our module
    handles that gracefully so this should always succeed.
    """
    pass


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestFetchSessionsReturnsList:
    """fetch_sessions should translate myair-py SleepRecords into plain dicts."""

    @pytest.mark.asyncio
    async def test_fetch_sessions_returns_list(self):
        mock_myair_module = MagicMock()

        records = [
            _make_sleep_record(startDate="2025-08-15", ahi=2.3, totalUsage=420, leakPercentile=12.5),
            _make_sleep_record(startDate="2025-08-14", ahi=1.1, totalUsage=390, leakPercentile=8.0),
        ]

        # Mock the client instance returned by ClientFactory
        mock_client_instance = AsyncMock()
        mock_client_instance.connect = AsyncMock(return_value="token")
        mock_client_instance.get_sleep_records = AsyncMock(return_value=records)

        mock_factory = MagicMock()
        mock_factory.return_value.get.return_value = mock_client_instance

        mock_myair_module.ClientFactory = mock_factory
        mock_myair_module.MyAirConfig = MagicMock(side_effect=lambda **kw: kw)
        mock_myair_module.AuthenticationError = type("AuthenticationError", (Exception,), {})

        with patch.dict("sys.modules", {"myair_py": mock_myair_module}):
            # Force re-import so the module picks up our mock
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]
            from resmed_client import MyAirClient as Client

            client = Client(username="user@example.com", password="secret", region="NA")
            result = await client.fetch_sessions(days=7)

        assert isinstance(result, list)
        assert len(result) == 2
        first = result[0]
        assert first["date"] == "2025-08-15"
        assert first["ahi"] == 2.3
        assert first["total_usage_minutes"] == 420
        assert first["leak_percentile"] == 12.5
        # mean_pressure may be None when API doesn't provide it
        assert "mean_pressure" in first


class TestAuthFailureRaisesMyAirAuthError:
    """Authentication failures should be re-raised as MyAirAuthError."""

    @pytest.mark.asyncio
    async def test_auth_failure_raises_myair_auth_error(self):
        mock_myair_module = MagicMock()

        mock_auth_error = type("AuthenticationError", (Exception,), {})

        mock_client_instance = AsyncMock()
        mock_client_instance.connect = AsyncMock(side_effect=mock_auth_error("Invalid credentials"))

        mock_factory = MagicMock()
        mock_factory.return_value.get.return_value = mock_client_instance

        mock_myair_module.ClientFactory = mock_factory
        mock_myair_module.MyAirConfig = MagicMock(side_effect=lambda **kw: kw)
        mock_myair_module.AuthenticationError = mock_auth_error

        with patch.dict("sys.modules", {"myair_py": mock_myair_module}):
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]
            from resmed_client import MyAirClient as Client, MyAirAuthError

            client = Client(username="user@example.com", password="secret", region="NA")
            with pytest.raises(MyAirAuthError, match="Invalid credentials"):
                await client.fetch_sessions()


class TestApiErrorRaisesMyAirAPIError:
    """Unexpected errors from the myair library should become MyAirAPIError."""

    @pytest.mark.asyncio
    async def test_api_error_raises_myair_api_error(self):
        mock_myair_module = MagicMock()

        mock_client_instance = AsyncMock()
        mock_client_instance.connect = AsyncMock(return_value="token")
        mock_client_instance.get_sleep_records = AsyncMock(
            side_effect=RuntimeError("AppSync query failed")
        )

        mock_factory = MagicMock()
        mock_factory.return_value.get.return_value = mock_client_instance

        mock_myair_module.ClientFactory = mock_factory
        mock_myair_module.MyAirConfig = MagicMock(side_effect=lambda **kw: kw)
        mock_myair_module.AuthenticationError = type("AuthenticationError", (Exception,), {})

        with patch.dict("sys.modules", {"myair_py": mock_myair_module}):
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]
            from resmed_client import MyAirClient as Client, MyAirAPIError

            client = Client(username="user@example.com", password="secret", region="NA")
            with pytest.raises(MyAirAPIError, match="AppSync query failed"):
                await client.fetch_sessions()


class TestEmptyResponseReturnsEmptyList:
    """When the API returns no records, fetch_sessions should return []."""

    @pytest.mark.asyncio
    async def test_empty_response_returns_empty_list(self):
        mock_myair_module = MagicMock()

        mock_client_instance = AsyncMock()
        mock_client_instance.connect = AsyncMock(return_value="token")
        mock_client_instance.get_sleep_records = AsyncMock(return_value=[])

        mock_factory = MagicMock()
        mock_factory.return_value.get.return_value = mock_client_instance

        mock_myair_module.ClientFactory = mock_factory
        mock_myair_module.MyAirConfig = MagicMock(side_effect=lambda **kw: kw)
        mock_myair_module.AuthenticationError = type("AuthenticationError", (Exception,), {})

        with patch.dict("sys.modules", {"myair_py": mock_myair_module}):
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]
            from resmed_client import MyAirClient as Client

            client = Client(username="user@example.com", password="secret", region="NA")
            result = await client.fetch_sessions(days=7)

        assert result == []


class TestMalformedRecordSkipped:
    """Records missing required fields should be skipped without crashing."""

    @pytest.mark.asyncio
    async def test_malformed_record_skipped(self):
        mock_myair_module = MagicMock()

        records = [
            # Good record
            _make_sleep_record(startDate="2025-08-15", ahi=2.3),
            # Malformed: missing ahi and totalUsage entirely
            {"startDate": "2025-08-14", "sleepScore": 50},
            # Malformed: no startDate
            {"ahi": 1.5, "totalUsage": 300},
            # Good record
            _make_sleep_record(startDate="2025-08-13", ahi=0.9),
        ]

        mock_client_instance = AsyncMock()
        mock_client_instance.connect = AsyncMock(return_value="token")
        mock_client_instance.get_sleep_records = AsyncMock(return_value=records)

        mock_factory = MagicMock()
        mock_factory.return_value.get.return_value = mock_client_instance

        mock_myair_module.ClientFactory = mock_factory
        mock_myair_module.MyAirConfig = MagicMock(side_effect=lambda **kw: kw)
        mock_myair_module.AuthenticationError = type("AuthenticationError", (Exception,), {})

        with patch.dict("sys.modules", {"myair_py": mock_myair_module}):
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]
            from resmed_client import MyAirClient as Client

            client = Client(username="user@example.com", password="secret", region="NA")
            result = await client.fetch_sessions(days=7)

        # Only the two well-formed records should come through
        assert len(result) == 2
        assert result[0]["date"] == "2025-08-15"
        assert result[1]["date"] == "2025-08-13"


class TestMyAirNotInstalledRaises:
    """When myair_py is not importable, creating a client should fail clearly."""

    def test_myair_not_installed_raises(self):
        # Temporarily hide myair_py from the import system
        with patch.dict("sys.modules", {"myair_py": None}):
            if "resmed_client" in sys.modules:
                del sys.modules["resmed_client"]

            # Re-import the module so it sees myair_py as missing
            import resmed_client
            importlib.reload(resmed_client)

            with pytest.raises(resmed_client.MyAirAPIError, match="myair_py.*not installed"):
                resmed_client.MyAirClient(
                    username="user@example.com",
                    password="secret",
                    region="NA",
                )
