"""Thin wrapper around the myair-py package for fetching ResMed CPAP data.

Translates myair-py's async client and SleepRecord TypedDicts into plain
dicts with keys matching our cpap_sessions schema.  All exceptions from
the underlying library are caught and re-raised as MyAirAuthError (for
credential problems) or MyAirAPIError (for everything else).
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Custom exceptions
# ---------------------------------------------------------------------------


class MyAirAuthError(Exception):
    """Raised when myAir authentication fails (bad credentials, 2FA, etc.)."""


class MyAirAPIError(Exception):
    """Raised for any non-auth error from the myAir API or missing dependency."""


# ---------------------------------------------------------------------------
# Attempt to import myair_py — defer failure to instantiation time so the
# module can always be imported (useful for tests & introspection).
# ---------------------------------------------------------------------------

_myair = None
_import_error: str | None = None

try:
    import myair_py as _myair  # type: ignore[no-redef]
except ImportError:
    _import_error = (
        "myair_py is not installed. "
        "Install it with: pip install myair-py"
    )


# ---------------------------------------------------------------------------
# Required keys that a sleep record must have to be considered valid.
# If any of these are missing the record is skipped.
# ---------------------------------------------------------------------------

_REQUIRED_RECORD_KEYS = {"startDate", "ahi", "totalUsage"}


def _normalize_record(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Convert a myair-py SleepRecord dict to our canonical format.

    Returns None if the record is missing required fields, so the caller
    can skip it without crashing the whole sync.
    """
    if not isinstance(raw, dict):
        logger.warning("Skipping non-dict sleep record: %s", type(raw).__name__)
        return None

    missing = _REQUIRED_RECORD_KEYS - raw.keys()
    if missing:
        logger.warning("Skipping malformed sleep record (missing %s): %s", missing, raw.get("startDate", "?"))
        return None

    try:
        return {
            "date": raw["startDate"],
            "ahi": float(raw["ahi"]),
            "total_usage_minutes": int(raw["totalUsage"]),
            "leak_percentile": _safe_float(raw.get("leakPercentile")),
            "mean_pressure": None,  # myAir API does not expose pressure data
        }
    except (ValueError, TypeError) as exc:
        logger.warning("Skipping record with bad data (%s): %s", exc, raw.get("startDate", "?"))
        return None


def _safe_float(value: Any) -> float | None:
    """Convert to float, returning None for missing or unconvertible values."""
    if value is None:
        return None
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class MyAirClient:
    """Wrapper around myair-py that returns plain dicts for CPAP sessions.

    Usage::

        client = MyAirClient(username="...", password="...", region="NA")
        sessions = await client.fetch_sessions(days=7)
        # sessions is a list of dicts with keys:
        #   date, ahi, total_usage_minutes, leak_percentile, mean_pressure
    """

    def __init__(self, *, username: str, password: str, region: str = "NA") -> None:
        if _myair is None:
            raise MyAirAPIError(_import_error)

        self._username = username
        self._password = password
        self._region = region

    async def fetch_sessions(self, days: int = 7) -> list[dict[str, Any]]:
        """Fetch recent CPAP sessions from the myAir API.

        Parameters
        ----------
        days:
            Number of days of history to request.  The myAir API may return
            up to 30 days regardless; we pass the parameter for future use.

        Returns
        -------
        list[dict]
            Each dict has keys: date, ahi, total_usage_minutes,
            leak_percentile, mean_pressure.
        """
        assert _myair is not None  # guarded in __init__

        try:
            config = _myair.MyAirConfig(
                username=self._username,
                password=self._password,
                region=self._region,
            )
            client = _myair.ClientFactory(config=config, session=None).get()
            await client.connect()
            raw_records = await client.get_sleep_records()
        except _myair.AuthenticationError as exc:
            raise MyAirAuthError(str(exc)) from exc
        except (MyAirAuthError, MyAirAPIError):
            # Don't double-wrap our own exceptions
            raise
        except Exception as exc:
            raise MyAirAPIError(str(exc)) from exc

        results: list[dict[str, Any]] = []
        for raw in raw_records:
            normalized = _normalize_record(raw)
            if normalized is not None:
                results.append(normalized)

        logger.info(
            "Fetched %d sessions from myAir (%d skipped)",
            len(results),
            len(raw_records) - len(results),
        )
        return results
