"""ResMed myAir API client — fetches CPAP session data.

Implements the Okta PKCE OAuth flow directly (myair-py's connect() is broken)
then uses the myair-py RESTClient for the GraphQL data queries.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import re
import secrets
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Custom exceptions
# ---------------------------------------------------------------------------


class MyAirAuthError(Exception):
    """Raised when myAir authentication fails (bad credentials, 2FA, etc.)."""


class MyAirAPIError(Exception):
    """Raised for any non-auth error from the myAir API."""


# ---------------------------------------------------------------------------
# Okta / myAir constants
# ---------------------------------------------------------------------------

OKTA_BASE = "https://resmed-ext-1.okta.com"
OKTA_AUTHN_URL = f"{OKTA_BASE}/api/v1/authn"
OKTA_AUTHORIZE_URL = f"{OKTA_BASE}/oauth2/aus4ccsxvnidQgLmA297/v1/authorize"
OKTA_TOKEN_URL = f"{OKTA_BASE}/oauth2/aus4ccsxvnidQgLmA297/v1/token"
OKTA_CLIENT_ID = "0oa4ccq1v413ypROi297"
REDIRECT_URI = "https://myair.resmed.com"

# myAir AppSync GraphQL endpoint
APPSYNC_URL = "https://ds53oalfjba5nkynjzg5gfmxnm.appsync-api.us-west-2.amazonaws.com/graphql"

# GraphQL query for sleep records
SLEEP_RECORDS_QUERY = """
query GetSleepRecords {
    getPatientWrapper {
        sleepRecords {
            items {
                startDate
                totalUsage
                sleepScore
                usageScore
                ahiScore
                maskScore
                leakScore
                ahi
                maskPairCount
                leakPercentile
                sleepRecordPatientId
                __typename
            }
        }
    }
}
"""


# ---------------------------------------------------------------------------
# Record normalization
# ---------------------------------------------------------------------------

_REQUIRED_RECORD_KEYS = {"startDate", "ahi", "totalUsage"}


def _normalize_record(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Convert a myAir SleepRecord dict to our canonical format."""
    if not isinstance(raw, dict):
        logger.warning("Skipping non-dict sleep record: %s", type(raw).__name__)
        return None

    missing = _REQUIRED_RECORD_KEYS - raw.keys()
    if missing:
        logger.warning("Skipping malformed record (missing %s): %s", missing, raw.get("startDate", "?"))
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
    """Fetches CPAP session data from ResMed's myAir cloud.

    Implements the Okta PKCE OAuth flow directly, then queries the
    AppSync GraphQL API for sleep records.

    Usage::

        client = MyAirClient(username="...", password="...")
        sessions = await client.fetch_sessions(days=7)
    """

    def __init__(self, *, username: str, password: str, region: str = "NA") -> None:
        self._username = username
        self._password = password
        self._region = region

    async def _authenticate(self, session: aiohttp.ClientSession) -> str:
        """Run the Okta PKCE OAuth flow and return an access token."""

        # Step 1: Okta primary authentication
        resp = await session.post(
            OKTA_AUTHN_URL,
            json={"username": self._username, "password": self._password},
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        data = await resp.json()

        if data.get("status") != "SUCCESS":
            error_summary = data.get("errorSummary", data.get("status", "Unknown error"))
            raise MyAirAuthError(f"Okta authentication failed: {error_summary}")

        session_token = data["sessionToken"]
        logger.debug("Got Okta session token")

        # Step 2: PKCE code challenge
        verifier = secrets.token_urlsafe(32)
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()
        ).rstrip(b"=").decode()

        # Step 3: Authorize (get auth code via okta_post_message)
        params = {
            "client_id": OKTA_CLIENT_ID,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "nonce": secrets.token_urlsafe(32),
            "prompt": "none",
            "redirect_uri": REDIRECT_URI,
            "response_mode": "okta_post_message",
            "response_type": "code",
            "sessionToken": session_token,
            "state": secrets.token_urlsafe(32),
            "scope": "openid profile email",
        }
        resp = await session.get(OKTA_AUTHORIZE_URL, params=params)
        body = await resp.text()

        # Parse auth code from the HTML postMessage response
        match = re.search(r"data\.code\s*=\s*'([^']+)'", body)
        if not match:
            # Check for error in response
            err_match = re.search(r"data\.error\s*=\s*'([^']+)'", body)
            error_msg = err_match.group(1) if err_match else "Could not extract auth code"
            raise MyAirAuthError(f"OAuth authorize failed: {error_msg}")

        auth_code = match.group(1)
        logger.debug("Got OAuth auth code")

        # Step 4: Exchange code for tokens
        resp = await session.post(
            OKTA_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "client_id": OKTA_CLIENT_ID,
                "code": auth_code,
                "code_verifier": verifier,
                "redirect_uri": REDIRECT_URI,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        token_data = await resp.json()

        access_token = token_data.get("access_token")
        if not access_token:
            error = token_data.get("error_description", token_data.get("error", "No access token"))
            raise MyAirAuthError(f"Token exchange failed: {error}")

        logger.debug("Got access token")
        return access_token

    async def _fetch_sleep_records(self, session: aiohttp.ClientSession, token: str) -> list[dict]:
        """Query the AppSync GraphQL API for sleep records."""
        resp = await session.post(
            APPSYNC_URL,
            json={"query": SLEEP_RECORDS_QUERY},
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )

        if resp.status != 200:
            body = await resp.text()
            raise MyAirAPIError(f"AppSync returned {resp.status}: {body[:200]}")

        data = await resp.json()

        if "errors" in data:
            raise MyAirAPIError(f"GraphQL errors: {data['errors']}")

        try:
            items = data["data"]["getPatientWrapper"]["sleepRecords"]["items"]
        except (KeyError, TypeError) as exc:
            raise MyAirAPIError(f"Unexpected response structure: {exc}") from exc

        return items

    async def fetch_sessions(self, days: int = 7) -> list[dict[str, Any]]:
        """Fetch recent CPAP sessions from myAir.

        Returns list of dicts with keys: date, ahi, total_usage_minutes,
        leak_percentile, mean_pressure.
        """
        async with aiohttp.ClientSession() as session:
            try:
                token = await self._authenticate(session)
            except MyAirAuthError:
                raise
            except Exception as exc:
                raise MyAirAuthError(f"Authentication failed: {repr(exc)}") from exc

            try:
                raw_records = await self._fetch_sleep_records(session, token)
            except (MyAirAuthError, MyAirAPIError):
                raise
            except Exception as exc:
                raise MyAirAPIError(f"API error: {repr(exc)}") from exc

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
