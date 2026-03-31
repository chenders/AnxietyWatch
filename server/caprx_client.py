"""Capital Rx claims history client.

Authenticates via Included Health SSO (SAML) and fetches pharmacy claims
from the CapRx member API. No browser needed — uses plain HTTP requests.

Auth flow:
    1. POST app-authnz.cap-rx.com/login/challenge → SAML redirect URL
    2. Follow SAML redirect → Included Health login page (Ory Kratos)
    3. POST Kratos credentials → session + continue_with URL
    4. Follow OAuth/SAML response chain → resolve_id
    5. POST app-authnz.cap-rx.com/sso/resolve → access + refresh tokens
    6. POST app-api.cap-rx.com/member/claim/list → claims data

Token lifecycle:
    - Access token: 15-minute lifetime
    - Refresh token: single-use, exchanged via sts.cap-rx.com/token/refresh
"""

from __future__ import annotations

import html
import logging
import re
from datetime import datetime
from typing import Any
from urllib.parse import urljoin, urlparse, parse_qs

import requests

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Custom exceptions
# ---------------------------------------------------------------------------


class CapRxAuthError(Exception):
    """Raised when authentication fails."""


class CapRxAPIError(Exception):
    """Raised for non-auth API errors."""


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/146.0.0.0 Safari/537.36"
    ),
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;"
        "q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,"
        "application/signed-exchange;v=b3;q=0.7"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
}

AUTHNZ_BASE = "https://app-authnz.cap-rx.com"
API_BASE = "https://app-api.cap-rx.com"
STS_BASE = "https://sts.cap-rx.com"
APP_ORIGIN = "https://app.cap-rx.com"

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


def _session_with_timeout(timeout: int) -> requests.Session:
    """Create a requests.Session with a default timeout on all methods."""
    session = requests.Session()
    orig_request = session.request

    def request_with_timeout(*args, **kwargs):
        kwargs.setdefault("timeout", timeout)
        return orig_request(*args, **kwargs)

    session.request = request_with_timeout  # type: ignore[method-assign]
    return session


class CapRxClient:
    """Stateless client for CapRx claims API."""

    REQUEST_TIMEOUT = 30  # seconds

    def __init__(self, email: str, password: str):
        self.email = email
        self.password = password
        self.access_token: str | None = None
        self.refresh_token: str | None = None

    # -- Public API --------------------------------------------------------

    def authenticate(self) -> None:
        """Run the full SSO login flow to obtain access + refresh tokens."""
        session = _session_with_timeout(self.REQUEST_TIMEOUT)
        session.headers.update(BROWSER_HEADERS)

        # Step 1: Login challenge → SAML redirect
        logger.info("CapRx: requesting login challenge")
        r = session.post(
            f"{AUTHNZ_BASE}/login/challenge",
            json={"identity": self.email},
            headers={
                "Content-Type": "application/json",
                "Origin": APP_ORIGIN,
                "Referer": f"{APP_ORIGIN}/",
            },
        )
        r.raise_for_status()
        challenge = r.json()
        saml_url = challenge.get("redirect")
        if not saml_url:
            raise CapRxAuthError(f"No redirect in login challenge: {challenge}")

        # Step 2: Follow SAML redirect → Included Health login page
        logger.info("CapRx: following SAML redirect to Included Health")
        r = session.get(saml_url, allow_redirects=True)
        r.raise_for_status()

        action_match = re.search(r'action="([^"]*)"', r.text)
        csrf_match = re.findall(
            r'name="csrf_token"\s+value="([^"]*)"', r.text
        )
        if not action_match or not csrf_match:
            raise CapRxAuthError("Could not find login form on Included Health page")

        # Step 3: POST credentials to Kratos
        logger.info("CapRx: posting credentials to Included Health")
        r = session.post(
            action_match.group(1),
            data={
                "csrf_token": csrf_match[0],
                "identifier": self.email,
                "password": self.password,
                "method": "password",
            },
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Origin": "https://login.includedhealth.com",
                "Referer": r.url,
            },
            allow_redirects=False,
        )
        if r.status_code == 400:
            raise CapRxAuthError("Invalid credentials")
        if r.status_code != 200:
            raise CapRxAuthError(f"Unexpected login response: {r.status_code}")

        data = r.json()
        continue_with = data.get("continue_with", [])
        if not continue_with:
            raise CapRxAuthError("No continue_with in login response")
        continue_url = continue_with[0].get("redirect_browser_to", "")
        if not continue_url.startswith("http"):
            continue_url = f"https://login.includedhealth.com{continue_url}"

        # Step 4: Follow OAuth/SAML response chain → resolve_id
        logger.info("CapRx: following post-login redirect chain")
        resolve_id = self._follow_saml_chain(session, continue_url)
        if not resolve_id:
            raise CapRxAuthError("Could not obtain resolve_id from SSO chain")

        # Step 5: Exchange resolve_id for tokens
        logger.info("CapRx: resolving tokens")
        r = session.post(
            f"{AUTHNZ_BASE}/sso/resolve",
            json={"resolve_id": resolve_id},
            headers={
                "Content-Type": "application/json",
                "Origin": APP_ORIGIN,
            },
        )
        r.raise_for_status()
        tokens = r.json()

        self.access_token = tokens.get("access_token")
        self.refresh_token = tokens.get("refresh_token")

        if not self.access_token:
            raise CapRxAuthError(f"No access_token in resolve response: {list(tokens.keys())}")

        logger.info("CapRx: authentication successful")

    def fetch_claims(self, page: int = 0, page_size: int = 100) -> dict[str, Any]:
        """Fetch pharmacy claims. Returns the full API response."""
        if not self.access_token:
            raise CapRxAuthError("Not authenticated — call authenticate() first")

        r = requests.post(
            f"{API_BASE}/member/claim/list",
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Content-Type": "application/json",
                "User-Agent": BROWSER_HEADERS["User-Agent"],
                "Origin": APP_ORIGIN,
                "Referer": f"{APP_ORIGIN}/",
            },
            json={"page": page, "page_size": page_size},
            timeout=self.REQUEST_TIMEOUT,
        )
        if r.status_code == 401:
            raise CapRxAuthError("Access token expired")
        r.raise_for_status()
        return r.json()

    def fetch_all_claims(self) -> list[dict[str, Any]]:
        """Fetch all pharmacy claims across all pages."""
        all_claims = []
        page = 0
        while True:
            data = self.fetch_claims(page=page, page_size=100)
            results = data.get("results", [])
            if not results:
                break
            all_claims.extend(results)
            total = int(data.get("result_count", 0))
            if len(all_claims) >= total:
                break
            page += 1
        logger.info("CapRx: fetched %d claims total", len(all_claims))
        return all_claims

    # -- Internal ----------------------------------------------------------

    def _follow_saml_chain(self, session: requests.Session, start_url: str) -> str | None:
        """Follow the post-login redirect chain until we find resolve_id."""
        url = start_url
        for _ in range(20):
            r = session.get(url, allow_redirects=False)
            location = r.headers.get("Location", "")

            # Check for SAML response form (auto-submit)
            if r.status_code == 200 and "SAMLResponse" in (r.text or ""):
                resolve_id = self._post_saml_form(session, r.text, url)
                if resolve_id:
                    return resolve_id

            # Check for resolve_id in redirect
            if "resolve_id" in location:
                return parse_qs(urlparse(location).query).get("resolve_id", [None])[0]
            if "resolve_id" in url:
                return parse_qs(urlparse(url).query).get("resolve_id", [None])[0]

            if not location:
                break
            url = location if location.startswith("http") else urljoin(url, location)

        return None

    def _post_saml_form(self, session: requests.Session, page_html: str, referer: str) -> str | None:
        """Extract and POST a SAML response form, return resolve_id if found."""
        saml_match = re.search(r'name="SAMLResponse"\s+value="([^"]*)"', page_html)
        action_match = re.search(r'action="([^"]*)"', page_html)
        relay_match = re.search(r'name="RelayState"\s+value="([^"]*)"', page_html)

        if not saml_match or not action_match:
            return None

        # HTML-decode values (&#43; → + etc.)
        post_data = {"SAMLResponse": html.unescape(saml_match.group(1))}
        if relay_match:
            post_data["RelayState"] = html.unescape(relay_match.group(1))

        action_url = html.unescape(action_match.group(1))
        r = session.post(
            action_url,
            data=post_data,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Origin": "https://sso.includedhealth.com",
                "Referer": referer,
            },
            allow_redirects=True,
        )

        # Check final URL and history for resolve_id
        for resp in list(r.history) + [r]:
            if "resolve_id" in resp.url:
                return parse_qs(urlparse(resp.url).query).get("resolve_id", [None])[0]

        return None


# ---------------------------------------------------------------------------
# Claim normalization
# ---------------------------------------------------------------------------

def _parse_float(value) -> float | None:
    """Parse a float from a string or number, returning None on failure."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def normalize_claim(claim_wrapper: dict[str, Any]) -> dict[str, Any] | None:
    """Convert a CapRx claim API result into a prescription dict for upsert.

    Returns None if the claim is missing required fields.
    """
    claim = claim_wrapper.get("claim") or {}
    if not isinstance(claim, dict):
        return None

    # Log available fields on first call for API documentation
    if not hasattr(normalize_claim, "_keys_logged"):
        wrapper_keys = sorted(claim_wrapper.keys())
        claim_keys = sorted(claim.keys())
        logger.info("CapRx claim wrapper keys: %s", wrapper_keys)
        logger.info("CapRx claim keys: %s", claim_keys)
        normalize_claim._keys_logged = True

    # Filter reversed/rejected claims if the API provides status
    claim_status = (
        claim.get("claim_status", "")
        or claim.get("status", "")
        or claim_wrapper.get("status", "")
    )
    if isinstance(claim_status, str) and claim_status.lower() in (
        "reversed", "rejected", "denied", "voided",
    ):
        logger.info("Skipping %s claim", claim_status)
        return None

    drug_name = claim.get("drug_name", "").strip()
    if not drug_name:
        return None

    date_str = claim.get("date_of_service", "")
    try:
        date_filled = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None

    # Build rx_number from claim ID + date (CapRx doesn't expose pharmacy rx numbers)
    claim_id = str(claim.get("id", ""))
    rx_number = f"CRX-{claim_id}" if claim_id else None
    if not rx_number:
        return None

    # Parse dosage
    dosage = claim.get("dosage", "")
    strength = claim.get("strength", "")
    strength_unit = claim.get("strength_unit_of_measure", "")
    dose_description = dosage or f"{strength}{strength_unit}"

    dose_mg = 0.0
    if strength:
        try:
            dose_mg = float(strength)
            if strength_unit.upper() == "MCG":
                dose_mg /= 1000
        except ValueError:
            pass

    quantity = 0
    try:
        quantity = int(float(claim.get("quantity_dispensed", 0)))
    except (ValueError, TypeError):
        pass

    try:
        days_supply = int(float(claim.get("days_supply", 0) or 0))
    except (ValueError, TypeError):
        days_supply = 0

    return {
        "rx_number": rx_number,
        "medication_name": drug_name,
        "dose_mg": dose_mg,
        "dose_description": dose_description,
        "quantity": quantity,
        "date_filled": date_filled,
        "pharmacy_name": claim.get("pharmacy_name") or "",
        "ndc_code": claim.get("ndc") or "",
        "days_supply": days_supply,
        "patient_pay": _parse_float(claim.get("patient_pay_amount")),
        "plan_pay": _parse_float(claim.get("plan_pay_amount")),
        "drug_type": claim.get("drug_type") or "",
        "dosage_form": claim.get("dosage_form") or "",
        "rx_status": str(claim_status) if claim_status else "",
    }
