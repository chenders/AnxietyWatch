"""Walgreens prescription history client.

Authenticates with walgreens.com and fetches prescription records using
Playwright (headless Chromium) to bypass bot detection (Akamai WAF).

Auth flow (driven via browser automation):
    1. Navigate to login page, fill credentials, click Sign In
    2. Handle 2FA security question if prompted
    3. Navigate to Prescription Records page
    4. Intercept the POST /rx-settings/printrx/load API response

Prescription data comes from the printrx/load JSON response containing
rxRecords[] with drug name, fill date, quantity, prescriber, NDC, etc.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from typing import Any

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
LOGIN_URL = f"{BASE_URL}/login.jsp"
RX_RECORDS_URL = f"{BASE_URL}/rx-settings/print-rx"
PRINTRX_API = "/rx-settings/printrx/load"


# ---------------------------------------------------------------------------
# Record normalization
# ---------------------------------------------------------------------------

_REQUIRED_FIELDS = {"drugName", "rxNumber", "fillDate"}


def _parse_dose(drug_name: str) -> tuple[float, str]:
    """Extract dose_mg and dose_description from a drug name.

    Returns (dose_mg, dose_description).
    """
    match = re.search(
        r'(\d+(?:\.\d+)?)\s*(mg|mcg|ml)\b', drug_name, re.IGNORECASE
    )
    if not match:
        return 0.0, ""
    value = float(match.group(1))
    unit = match.group(2).lower()
    desc = f"{match.group(1)}{match.group(2)}"
    if unit == "mcg":
        value /= 1000  # convert to mg
    elif unit == "ml":
        # ml is not convertible to mg without concentration
        return 0.0, desc
    return value, desc


def _parse_price(price_str: str | None) -> float | None:
    """Parse '$15.49' -> 15.49, or None."""
    if not price_str:
        return None
    match = re.search(r'\$?([\d,]+\.?\d*)', price_str)
    if match:
        return float(match.group(1).replace(",", ""))
    return None


def _parse_walgreens_date(date_str: str) -> str:
    """Convert Walgreens MM/DD/YYYY to ISO-8601 with UTC timezone."""
    try:
        return datetime.strptime(date_str, "%m/%d/%Y").strftime(
            "%Y-%m-%dT00:00:00+00:00"
        )
    except (ValueError, TypeError):
        return date_str


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
        "date_filled": _parse_walgreens_date(raw["fillDate"]),
        "pharmacy_name": "Walgreens",
        "prescriber_name": prescriber_name,
        "ndc_code": raw.get("ndcNumber", ""),
        "rx_status": raw.get("prescriptionType", ""),
        "directions": "",
        "import_source": "walgreens",
        "walgreens_rx_id": raw["rxNumber"],
    }


# ---------------------------------------------------------------------------
# Client (Playwright-based)
# ---------------------------------------------------------------------------


class WalgreensClient:
    """Fetches prescription history from walgreens.com using Playwright.

    Uses headless Chromium to bypass Walgreens' Akamai bot detection,
    which blocks raw HTTP clients like requests.

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
        self._storage_state: dict | None = None

    def _load_session(self, cookie_data: str) -> None:
        """Restore a previously saved browser state."""
        try:
            self._storage_state = json.loads(cookie_data)
        except (json.JSONDecodeError, TypeError) as exc:
            logger.warning("Failed to restore session: %s", exc)
            self._storage_state = None

    def save_session(self) -> str:
        """Serialize current browser state for later reuse."""
        if self._storage_state:
            return json.dumps(self._storage_state)
        return "{}"

    def fetch_prescriptions(
        self,
        session_data: str | None = None,
        start_date: str = "",
        end_date: str = "",
    ) -> list[dict[str, Any]]:
        """Fetch prescription history, returning normalized dicts."""
        from playwright.sync_api import sync_playwright

        if session_data:
            self._load_session(session_data)

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)

            # Try session reuse first
            context = browser.new_context(
                storage_state=self._storage_state
                if self._storage_state
                else None,
            )
            page = context.new_page()

            try:
                raw_records = self._try_fetch(
                    page, start_date, end_date
                )
            except WalgreensAuthError:
                # Session expired or no session — do full login
                context.close()
                context = browser.new_context()
                page = context.new_page()
                self._authenticate(page)
                raw_records = self._try_fetch(
                    page, start_date, end_date
                )

            # Save browser state for next run
            self._storage_state = context.storage_state()
            context.close()
            browser.close()

        results = []
        for raw in raw_records:
            normalized = normalize_prescription(raw)
            if normalized is not None:
                results.append(normalized)

        logger.info(
            "Fetched %d prescriptions (%d raw, %d skipped)",
            len(results),
            len(raw_records),
            len(raw_records) - len(results),
        )
        return results

    def _authenticate(self, page) -> None:
        """Login via the browser, handling 2FA if needed."""
        logger.info("Navigating to Walgreens login page")
        page.goto(LOGIN_URL, wait_until="domcontentloaded")
        page.wait_for_timeout(2000)

        # Fill credentials
        try:
            page.fill('input[name="username"], #email', self._username)
            page.fill(
                'input[name="password"], #password', self._password
            )
        except Exception as exc:
            raise WalgreensAuthError(
                f"Could not find login form: {exc}"
            ) from exc

        # Click sign in and wait for navigation away from login page
        page.click('button:has-text("Sign in")')
        try:
            page.wait_for_url(
                lambda url: "login.jsp" not in url, timeout=15000
            )
        except Exception:
            raise WalgreensAuthError(
                "Login failed — page did not navigate after submission"
            )

        # Check for 2FA
        if "verify_identity" in page.url:
            if not self._security_answer:
                raise WalgreensAuthError(
                    "2FA required but no security_answer provided"
                )
            self._handle_2fa(page)

        logger.info("Successfully logged in to Walgreens")

    def _handle_2fa(self, page) -> None:
        """Handle 2FA security question."""
        logger.info("Handling 2FA security question")

        # Select "Answer your security question" option
        try:
            page.click(
                'text="Answer your security question"', timeout=5000
            )
            page.click('button:has-text("Continue")')
            page.wait_for_timeout(2000)
        except Exception:
            logger.warning("Could not select security question option")

        # Fill in the answer
        try:
            # Find the security question input field
            answer_input = page.locator(
                'input[type="text"], input[type="password"]'
            ).last
            answer_input.fill(self._security_answer)
            page.click('button:has-text("Submit")')
            page.wait_for_url(
                lambda url: "verify_identity" not in url, timeout=15000
            )
        except WalgreensAuthError:
            raise
        except Exception as exc:
            raise WalgreensAuthError(
                f"Failed to answer security question: {exc}"
            ) from exc

        logger.info("2FA verification complete")

    def _try_fetch(
        self,
        page,
        start_date: str,
        end_date: str,
    ) -> list[dict]:
        """Navigate to prescription records and capture the API response."""
        captured_data = {}

        def handle_response(response):
            if PRINTRX_API in response.url and response.status == 200:
                try:
                    captured_data["response"] = response.json()
                except Exception:
                    pass

        page.on("response", handle_response)

        logger.info("Navigating to prescription records page")
        page.goto(RX_RECORDS_URL, wait_until="domcontentloaded")

        if "login" in page.url.lower():
            raise WalgreensAuthError("Not authenticated")

        # Wait for the printrx/load API response (up to 30s)
        for _ in range(30):
            if "response" in captured_data:
                break
            page.wait_for_timeout(1000)

        if "response" not in captured_data:
            raise WalgreensAPIError(
                "No prescription data received from API"
            )

        data = captured_data["response"]
        records = data.get("rxRecords", [])
        logger.info(
            "Received %d prescription records from Walgreens", len(records)
        )
        return records
