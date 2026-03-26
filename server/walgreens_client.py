"""Walgreens prescription history client.

Authenticates with walgreens.com and fetches prescription records using
Playwright (headed Chrome) to bypass bot detection (Akamai WAF).

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

    Uses headed Chromium to bypass Walgreens' Akamai bot detection.
    Headless modes are detected; on servers use xvfb-run.

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
            logger.info("Loaded saved session data")
        else:
            logger.info("No saved session data")

        with sync_playwright() as p:
            # Akamai WAF detects all headless modes — must run headed.
            # On headless servers, use xvfb-run to provide a virtual display.
            logger.info("Launching Chromium (headed)")
            browser = p.chromium.launch(
                headless=False,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                ],
            )

            context_opts = {
                "viewport": {"width": 1280, "height": 800},
                "user_agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/131.0.0.0 Safari/537.36"
                ),
                "locale": "en-US",
                "timezone_id": "America/Los_Angeles",
                "geolocation": None,
                "permissions": [],
            }

            # Try session reuse first
            if self._storage_state:
                logger.info("Attempting session reuse")
                context = browser.new_context(
                    storage_state=self._storage_state,
                    **context_opts,
                )
            else:
                logger.info("No session to reuse, will do full login")
                context = browser.new_context(**context_opts)
            page = context.new_page()

            try:
                raw_records = self._try_fetch(
                    page, start_date, end_date
                )
            except WalgreensAuthError as exc:
                # Session expired or no session — do full login
                logger.info(
                    "Session fetch failed (%s), performing full login", exc
                )
                context.close()
                context = browser.new_context(**context_opts)
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
        page.wait_for_timeout(3000)
        logger.info("Login page loaded, URL: %s, title: %s", page.url, page.title())

        # Fill credentials — type character-by-character to avoid bot detection
        try:
            email_input = page.query_selector(
                'input[name="username"], #user_name, #email'
            )
            pwd_input = page.query_selector(
                'input[name="password"], #user_password, #password'
            )
            if not email_input or not pwd_input:
                # Log what inputs we can find
                inputs = page.query_selector_all('input')
                input_info = []
                for inp in inputs:
                    input_info.append(
                        f'name={inp.get_attribute("name")} '
                        f'id={inp.get_attribute("id")} '
                        f'type={inp.get_attribute("type")}'
                    )
                logger.error(
                    "Login form inputs not found. Available inputs: %s",
                    "; ".join(input_info),
                )
                raise WalgreensAuthError(
                    "Could not find login form fields"
                )
            logger.info("Found login form fields, typing credentials")
            email_input.click()
            email_input.type(self._username, delay=50)
            page.wait_for_timeout(500)
            pwd_input.click()
            pwd_input.type(self._password, delay=50)
            page.wait_for_timeout(1000)
        except WalgreensAuthError:
            raise
        except Exception as exc:
            logger.error("Error filling login form: %s", exc)
            raise WalgreensAuthError(
                f"Could not fill login form: {exc}"
            ) from exc

        # Click sign in and wait for navigation away from login page
        logger.info("Clicking Sign In button")
        sign_in_btn = page.query_selector('button:has-text("Sign in")')
        if not sign_in_btn:
            logger.error("Sign In button not found")
            raise WalgreensAuthError("Sign In button not found on page")
        sign_in_btn.click()

        logger.info("Waiting for navigation away from login.jsp...")
        try:
            page.wait_for_url(
                lambda url: "login.jsp" not in url, timeout=20000
            )
        except Exception as exc:
            logger.error(
                "Login did not navigate. Current URL: %s, page title: %s",
                page.url, page.title(),
            )
            # Try to capture any error message on the page
            error_el = page.query_selector(
                '.error, .alert-error, [role="alert"], .errMsg'
            )
            if error_el:
                logger.error(
                    "Page error message: %s", error_el.inner_text()
                )
            raise WalgreensAuthError(
                f"Login failed — page did not navigate. URL: {page.url}"
            ) from exc

        logger.info("Navigated to: %s", page.url)

        # Check for 2FA
        if "verify_identity" in page.url:
            logger.info("2FA verification required")
            if not self._security_answer:
                raise WalgreensAuthError(
                    "2FA required but no security_answer provided"
                )
            self._handle_2fa(page)

        logger.info("Successfully logged in to Walgreens, URL: %s", page.url)

    def _handle_2fa(self, page) -> None:
        """Handle 2FA security question.

        The verify_identity page presents three radio options:
          1. Email verification
          2. Text (SMS) verification
          3. Answer your security question
        We select option 3, click Continue, then fill the answer.
        """
        logger.info("Handling 2FA — selecting security question option")
        page.wait_for_timeout(2000)

        # Select the "Answer your security question" radio button
        sq_radio = page.query_selector('#radio-security-question')
        if not sq_radio:
            raise WalgreensAuthError(
                "Security question radio button not found on 2FA page"
            )
        sq_radio.click()
        page.wait_for_timeout(500)

        # Click Continue
        logger.info("Clicking Continue")
        continue_btn = page.locator('button:has-text("Continue"):visible')
        continue_btn.click()

        # Wait for the security question page to load
        logger.info("Waiting for security question form...")
        page.wait_for_timeout(3000)
        logger.info("Security question page URL: %s", page.url)

        # Find the security answer input (known id: secQues)
        target = page.query_selector('#secQues')
        if not target:
            # Fallback: find any visible text input not in the header
            target = page.query_selector(
                'input[name="SecurityAnswer"]:visible'
            )
        if not target:
            raise WalgreensAuthError(
                "Could not find security answer input field"
            )

        logger.info("Filling security question answer")
        target.click()
        target.type(self._security_answer, delay=50)
        page.wait_for_timeout(500)

        # Submit the answer
        logger.info("Clicking Submit / Continue")
        submit_btn = page.locator(
            'button:has-text("Submit"):visible, '
            'button:has-text("Continue"):visible'
        ).first
        submit_btn.click()

        logger.info("Waiting for navigation away from verify_identity...")
        try:
            page.wait_for_url(
                lambda url: "verify_identity" not in url, timeout=20000
            )
        except Exception as exc:
            logger.error(
                "2FA submit failed. URL: %s", page.url
            )
            raise WalgreensAuthError(
                f"Security question submission failed: {exc}"
            ) from exc

        logger.info("2FA complete, navigated to: %s", page.url)

    def _try_fetch(
        self,
        page,
        start_date: str,
        end_date: str,
    ) -> list[dict]:
        """Navigate to prescription records and capture the API response."""
        captured_data = {}

        def handle_response(response):
            if PRINTRX_API in response.url:
                logger.info(
                    "Intercepted %s response: HTTP %d",
                    response.url, response.status,
                )
                if response.status == 200:
                    try:
                        captured_data["response"] = response.json()
                        logger.info(
                            "Captured prescription data with %d records",
                            len(captured_data["response"].get("rxRecords", [])),
                        )
                    except Exception as exc:
                        logger.error(
                            "Failed to parse printrx response: %s", exc
                        )

        page.on("response", handle_response)

        logger.info("Navigating to prescription records page")
        page.goto(RX_RECORDS_URL, wait_until="domcontentloaded")
        logger.info(
            "Prescription records page loaded, URL: %s", page.url
        )

        if "login" in page.url.lower():
            logger.info("Redirected to login — not authenticated")
            raise WalgreensAuthError("Not authenticated")

        # Wait for the printrx/load API response (up to 30s)
        logger.info("Waiting for printrx/load API response...")
        for i in range(30):
            if "response" in captured_data:
                break
            page.wait_for_timeout(1000)
            if i > 0 and i % 5 == 0:
                logger.info(
                    "Still waiting for API response... (%ds)", i
                )

        if "response" not in captured_data:
            logger.error(
                "No prescription data received after 30s. "
                "Current URL: %s, page title: %s",
                page.url, page.title(),
            )
            raise WalgreensAPIError(
                "No prescription data received from API"
            )

        data = captured_data["response"]
        records = data.get("rxRecords", [])
        logger.info(
            "Received %d prescription records from Walgreens", len(records)
        )
        return records
