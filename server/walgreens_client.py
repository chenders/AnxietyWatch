"""Walgreens prescription history client.

Authenticates with walgreens.com and fetches prescription records via the
internal API.  Uses synchronous requests with session cookie management.

Auth flow:
    1. POST /profile/v1/login  — username/password → session cookies
    2. GET  /profile/verify_identity.jsp  — 2FA (security question)
    3. POST /profile/v1/verifyidentity/securityquestion — answer → full session

Prescription data:
    POST /rx-settings/printrx/load — returns JSON with rxRecords[]

Required headers for authenticated API calls:
    X-XSRF-TOKEN: <from XSRF-TOKEN cookie>
    usersessionid: <from session_id cookie>
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

import requests

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Custom exceptions
# ---------------------------------------------------------------------------


class WalgreensAuthError(Exception):
    """Raised when Walgreens authentication fails."""


class WalgreensAPIError(Exception):
    """Raised for non-auth API errors."""


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BASE_URL = "https://www.walgreens.com"
LOGIN_URL = f"{BASE_URL}/profile/v1/login"
VERIFY_IDENTITY_URL = f"{BASE_URL}/profile/v1/verifyidentity/securityquestion"
PRINTRX_URL = f"{BASE_URL}/rx-settings/printrx/load"

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"
)


# ---------------------------------------------------------------------------
# Record normalization
# ---------------------------------------------------------------------------

_REQUIRED_FIELDS = {"drugName", "rxNumber", "fillDate"}


def _parse_dose(drug_name: str) -> tuple[float, str]:
    """Extract dose_mg and dose_description from a drug name like 'Clonazepam 1mg Tablets'.

    Returns (dose_mg, dose_description).
    """
    match = re.search(r'(\d+(?:\.\d+)?)\s*(mg|mcg|ml)\b', drug_name, re.IGNORECASE)
    if not match:
        return 0.0, ""
    value = float(match.group(1))
    unit = match.group(2).lower()
    if unit == "mcg":
        value /= 1000  # convert to mg
    return value, f"{match.group(1)}{match.group(2)}"


def _parse_price(price_str: str | None) -> float | None:
    """Parse '$15.49' → 15.49, or None."""
    if not price_str:
        return None
    match = re.search(r'\$?([\d,]+\.?\d*)', price_str)
    if match:
        return float(match.group(1).replace(",", ""))
    return None


def normalize_prescription(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Convert a Walgreens rxRecord dict to our canonical format."""
    if not isinstance(raw, dict):
        return None

    missing = _REQUIRED_FIELDS - raw.keys()
    if missing:
        logger.warning("Skipping prescription missing %s", missing)
        return None

    dose_mg, dose_desc = _parse_dose(raw["drugName"])

    prescriber = raw.get("prescriber", {})
    prescriber_name = ""
    if prescriber:
        first = prescriber.get("firstName", "")
        last = prescriber.get("lastName", "")
        prescriber_name = f"{first} {last}".strip()

    return {
        "rx_number": raw["rxNumber"],
        "medication_name": raw["drugName"],
        "dose_mg": dose_mg,
        "dose_description": dose_desc,
        "quantity": int(raw.get("quantity", 0)),
        "refills_remaining": 0,
        "date_filled": raw["fillDate"],
        "pharmacy_name": "Walgreens",
        "prescriber_name": prescriber_name,
        "ndc_code": raw.get("ndcNumber", ""),
        "rx_status": raw.get("prescriptionType", ""),
        "directions": "",
        "import_source": "walgreens",
        "walgreens_rx_id": raw["rxNumber"],
    }


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class WalgreensClient:
    """Fetches prescription history from walgreens.com.

    Usage::

        client = WalgreensClient(
            username="...", password="...",
            security_answer="...",
        )
        prescriptions = client.fetch_prescriptions()
    """

    def __init__(
        self,
        *,
        username: str,
        password: str,
        security_answer: str = "",
    ) -> None:
        self._username = username
        self._password = password
        self._security_answer = security_answer
        self._session = requests.Session()
        self._session.headers.update({
            "User-Agent": USER_AGENT,
            "Accept": "application/json, text/html, */*",
        })

    def _get_xsrf_token(self) -> str:
        """Extract the XSRF-TOKEN cookie value."""
        token = self._session.cookies.get("XSRF-TOKEN", domain=".walgreens.com")
        if not token:
            # Try without domain restriction
            for cookie in self._session.cookies:
                if cookie.name == "XSRF-TOKEN":
                    return cookie.value
        return token or ""

    def _get_session_id(self) -> str:
        """Extract the session_id cookie value."""
        for cookie in self._session.cookies:
            if cookie.name == "session_id":
                return cookie.value
        return ""

    def _authenticate(self) -> None:
        """Login to walgreens.com, populating session cookies.

        Step 1: Hit login page to get initial cookies
        Step 2: POST credentials to /profile/v1/login
        Step 3: Handle 2FA security question if required
        """
        # Step 1: Get initial cookies
        try:
            self._session.get(
                f"{BASE_URL}/login.jsp",
                timeout=15,
            )
        except requests.RequestException as exc:
            raise WalgreensAuthError(f"Failed to load login page: {exc}") from exc

        # Step 2: POST login credentials
        xsrf = self._get_xsrf_token()
        try:
            resp = self._session.post(
                LOGIN_URL,
                json={
                    "username": self._username,
                    "password": self._password,
                },
                headers={
                    "Content-Type": "application/json",
                    "X-XSRF-TOKEN": xsrf,
                    "Referer": f"{BASE_URL}/login.jsp",
                },
                timeout=15,
            )
        except requests.RequestException as exc:
            raise WalgreensAuthError(f"Login request failed: {exc}") from exc

        if resp.status_code == 401:
            raise WalgreensAuthError("Invalid credentials")
        if resp.status_code != 200:
            raise WalgreensAuthError(f"Login failed with HTTP {resp.status_code}")

        logger.debug("Login response: %s", resp.status_code)

        # Step 3: Handle 2FA — attempt security question
        if self._security_answer:
            self._verify_security_question()

    def _verify_security_question(self) -> None:
        """Complete 2FA via security question answer."""
        xsrf = self._get_xsrf_token()
        session_id = self._get_session_id()

        # First, select the security question option
        try:
            resp = self._session.post(
                f"{BASE_URL}/profile/v1/verifyidentity",
                json={"optionType": "securityquestion"},
                headers={
                    "Content-Type": "application/json",
                    "X-XSRF-TOKEN": xsrf,
                    "usersessionid": session_id,
                    "Referer": f"{BASE_URL}/profile/verify_identity.jsp",
                },
                timeout=15,
            )
        except requests.RequestException as exc:
            raise WalgreensAuthError(f"2FA option selection failed: {exc}") from exc

        # Then submit the security question answer
        xsrf = self._get_xsrf_token()
        try:
            resp = self._session.post(
                VERIFY_IDENTITY_URL,
                json={"answer": self._security_answer},
                headers={
                    "Content-Type": "application/json",
                    "X-XSRF-TOKEN": xsrf,
                    "usersessionid": session_id,
                    "Referer": f"{BASE_URL}/profile/verify_identity.jsp",
                },
                timeout=15,
            )
        except requests.RequestException as exc:
            raise WalgreensAuthError(f"Security question verification failed: {exc}") from exc

        if resp.status_code != 200:
            raise WalgreensAuthError(
                f"Security question verification returned HTTP {resp.status_code}"
            )

        logger.debug("2FA security question verified")

    def _load_session(self, cookie_data: str) -> None:
        """Restore a previously saved session from serialized cookie JSON."""
        try:
            cookies = json.loads(cookie_data)
            for c in cookies:
                self._session.cookies.set(
                    c["name"], c["value"],
                    domain=c.get("domain", ".walgreens.com"),
                    path=c.get("path", "/"),
                )
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            logger.warning("Failed to restore session: %s", exc)

    def save_session(self) -> str:
        """Serialize current session cookies for later reuse."""
        cookies = []
        for c in self._session.cookies:
            cookies.append({
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
            })
        return json.dumps(cookies)

    def _fetch_rx_records(
        self,
        start_date: str = "",
        end_date: str = "",
    ) -> list[dict]:
        """Query the prescription records API."""
        xsrf = self._get_xsrf_token()
        session_id = self._get_session_id()

        payload = {
            "filter": {
                "startDate": start_date,
                "endDate": end_date,
                "dateRetained": False,
                "sortName": "filldate",
                "sortOrder": "descending",
                "switchFamilyMemeber": False,
                "filterBy": {
                    "prescriber": ["All"],
                    "prescriptionType": ["All"],
                },
            },
        }

        try:
            resp = self._session.post(
                PRINTRX_URL,
                json=payload,
                headers={
                    "Content-Type": "application/json; charset=UTF-8",
                    "Accept": "application/json",
                    "X-XSRF-TOKEN": xsrf,
                    "usersessionid": session_id,
                    "Referer": f"{BASE_URL}/rx-settings/print-rx",
                },
                timeout=30,
            )
        except requests.RequestException as exc:
            raise WalgreensAPIError(f"Prescription fetch failed: {exc}") from exc

        if resp.status_code == 401:
            raise WalgreensAuthError("Session expired — re-authentication required")
        if resp.status_code != 200:
            raise WalgreensAPIError(
                f"Prescription API returned HTTP {resp.status_code}"
            )

        try:
            data = resp.json()
        except ValueError:
            raise WalgreensAPIError(
                f"Prescription API returned non-JSON: {resp.text[:200]}"
            )

        return data.get("rxRecords", [])

    def fetch_prescriptions(
        self,
        session_data: str | None = None,
        start_date: str = "",
        end_date: str = "",
    ) -> list[dict[str, Any]]:
        """Fetch prescription history, returning normalized dicts.

        If *session_data* is provided, attempts to reuse the saved session
        before falling back to full authentication.

        *start_date* / *end_date* are MM/DD/YYYY strings. Empty = no filter.
        """
        authenticated = False

        # Try session reuse first
        if session_data:
            self._load_session(session_data)
            try:
                raw_records = self._fetch_rx_records(start_date, end_date)
                authenticated = True
            except WalgreensAuthError:
                logger.info("Saved session expired, performing full login")

        # Full login if session reuse didn't work
        if not authenticated:
            try:
                self._authenticate()
            except WalgreensAuthError:
                raise
            except Exception as exc:
                raise WalgreensAuthError(
                    f"Authentication failed: {repr(exc)}"
                ) from exc

            try:
                raw_records = self._fetch_rx_records(start_date, end_date)
            except WalgreensAPIError:
                raise
            except Exception as exc:
                raise WalgreensAPIError(
                    f"Fetch failed: {repr(exc)}"
                ) from exc

        results = []
        for raw in raw_records:
            normalized = normalize_prescription(raw)
            if normalized is not None:
                results.append(normalized)

        logger.info(
            "Fetched %d prescriptions (%d raw, %d skipped)",
            len(results), len(raw_records), len(raw_records) - len(results),
        )
        return results
