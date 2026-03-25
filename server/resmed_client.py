"""ResMed myAir API client — fetches CPAP session data.

Implements the Okta PKCE OAuth flow and queries the myAir GraphQL API.
Uses synchronous requests (no async) for simplicity and reliability.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta
from typing import Any

import requests

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

OKTA_AUTHN_URL = "https://resmed-ext-1.okta.com/api/v1/authn"
OKTA_AUTHORIZE_URL = "https://resmed-ext-1.okta.com/oauth2/aus4ccsxvnidQgLmA297/v1/authorize"
OKTA_TOKEN_URL = "https://resmed-ext-1.okta.com/oauth2/aus4ccsxvnidQgLmA297/v1/token"
OKTA_CLIENT_ID = "0oa4ccq1v413ypROi297"
REDIRECT_URI = "https://myair.resmed.com"

GRAPHQL_URL = "https://graphql.prd.hyperdrive.myair.resmed.com/graphql"


# ---------------------------------------------------------------------------
# Record normalization
# ---------------------------------------------------------------------------

_REQUIRED_RECORD_KEYS = {"startDate", "ahi", "totalUsage"}


def _normalize_record(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Convert a myAir SleepRecord dict to our canonical format."""
    if not isinstance(raw, dict):
        return None

    missing = _REQUIRED_RECORD_KEYS - raw.keys()
    if missing:
        logger.warning("Skipping record missing %s", missing)
        return None

    try:
        return {
            "date": raw["startDate"],
            "ahi": float(raw["ahi"]),
            "total_usage_minutes": int(raw["totalUsage"]),
            "leak_percentile": _safe_float(raw.get("leakPercentile")),
            "mean_pressure": None,
        }
    except (ValueError, TypeError) as exc:
        logger.warning("Skipping record: %s", exc)
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

    Usage::

        client = MyAirClient(username="...", password="...")
        sessions = client.fetch_sessions(days=30)
    """

    def __init__(self, *, username: str, password: str, region: str = "NA") -> None:
        self._username = username
        self._password = password
        self._region = region

    def _authenticate(self) -> str:
        """Run the Okta PKCE OAuth flow and return an access token."""

        # Step 1: Okta primary authentication
        resp = requests.post(
            OKTA_AUTHN_URL,
            json={"username": self._username, "password": self._password},
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()

        if data.get("status") != "SUCCESS":
            error = data.get("errorSummary", data.get("status", "Unknown error"))
            raise MyAirAuthError(f"Okta auth failed: {error}")

        session_token = data["sessionToken"]
        logger.debug("Got Okta session token")

        # Step 2: PKCE code challenge
        verifier = secrets.token_urlsafe(32)
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()
        ).rstrip(b"=").decode()

        # Step 3: Authorize — get auth code from HTML
        resp = requests.get(
            OKTA_AUTHORIZE_URL,
            params={
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
            },
            allow_redirects=False,
            timeout=15,
        )

        auth_code = None
        body = resp.text

        # Try HTML body (okta_post_message mode)
        match = re.search(r"data\.code\s*=\s*'([^']+)'", body)
        if match:
            auth_code = match.group(1)

        # Try Location header (redirect mode)
        if not auth_code and resp.status_code in (302, 303):
            location = resp.headers.get("Location", "")
            code_match = re.search(r"[?&]code=([^&]+)", location)
            if code_match:
                auth_code = code_match.group(1)

        if not auth_code:
            detail = resp.text[:200] if resp.status_code >= 400 else ""
            raise MyAirAuthError(
                f"No auth code (HTTP {resp.status_code}){': ' + detail if detail else ''}"
            )

        logger.debug("Got auth code")

        # Step 4: Exchange code for tokens
        resp = requests.post(
            OKTA_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "client_id": OKTA_CLIENT_ID,
                "code": auth_code,
                "code_verifier": verifier,
                "redirect_uri": REDIRECT_URI,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=15,
        )
        try:
            token_data = resp.json()
        except ValueError:
            raise MyAirAuthError(f"Token exchange returned non-JSON (HTTP {resp.status_code})")

        access_token = token_data.get("access_token")
        if not access_token:
            error = token_data.get("error_description", token_data.get("error", f"HTTP {resp.status_code}"))
            raise MyAirAuthError(f"Token exchange failed: {error}")

        logger.debug("Got access token")
        return access_token

    def _fetch_sleep_records(self, token: str, start: str, end: str) -> list[dict]:
        """Query the myAir GraphQL API for sleep records."""
        api_key = os.environ.get("GRAPHQL_API_KEY", "")
        if not api_key:
            raise MyAirAPIError("GRAPHQL_API_KEY env var not set")
        query = {
            "operationName": "getPatientWrapper",
            "variables": {},
            "query": (
                "query getPatientWrapper { getPatientWrapper { "
                f'sleepRecords(startMonth: "{start}", endMonth: "{end}") {{ '
                "items { startDate totalUsage sleepScore ahi leakPercentile "
                "maskPairCount __typename } } } }"
            ),
        }

        resp = requests.post(
            GRAPHQL_URL,
            data=json.dumps(query),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Origin": "https://myair.resmed.com",
                "Referer": "https://myair.resmed.com/",
                "Accept": "application/json, text/plain, */*",
                "rmdappversion": "2.0.0",
                "rmdcountry": self._region,
                "rmdhandsetid": str(uuid.uuid4()),
                "rmdhandsetmodel": "Python",
                "rmdhandsetosversion": "3.12",
                "rmdhandsetplatform": "Web",
                "rmdlanguage": "en",
                "rmdproduct": "myAir",
            },
            timeout=30,
        )

        if resp.status_code != 200:
            raise MyAirAPIError(f"GraphQL returned {resp.status_code}: {resp.text[:200]}")

        try:
            data = resp.json()
        except ValueError:
            raise MyAirAPIError(f"GraphQL returned non-JSON: {resp.text[:200]}")
        if "errors" in data:
            raise MyAirAPIError(f"GraphQL errors: {json.dumps(data['errors'])[:300]}")

        try:
            return data["data"]["getPatientWrapper"]["sleepRecords"]["items"]
        except (KeyError, TypeError) as exc:
            raise MyAirAPIError(f"Unexpected response: {exc}") from exc

    def fetch_sessions(self, days: int = 30) -> list[dict[str, Any]]:
        """Fetch recent CPAP sessions from myAir.

        Returns list of dicts with keys: date, ahi, total_usage_minutes,
        leak_percentile, mean_pressure.

        Raises MyAirAuthError for credential/auth issues,
        MyAirAPIError for network/API failures.
        """
        try:
            token = self._authenticate()
        except MyAirAuthError:
            raise
        except Exception as exc:
            raise MyAirAuthError(f"Authentication failed: {repr(exc)}") from exc

        now = datetime.now()
        start = (now - timedelta(days=days)).strftime("%Y-%m-%d")
        end = now.strftime("%Y-%m-%d")

        try:
            raw_records = self._fetch_sleep_records(token, start, end)
        except MyAirAPIError:
            raise
        except Exception as exc:
            raise MyAirAPIError(f"Fetch failed: {repr(exc)}") from exc

        results = []
        for raw in raw_records:
            normalized = _normalize_record(raw)
            if normalized is not None:
                results.append(normalized)

        logger.info(
            "Fetched %d sessions (%d raw, %d skipped)",
            len(results), len(raw_records), len(raw_records) - len(results),
        )
        return results
