"""Tests for the Walgreens prescription history client."""

import json
import logging
from unittest.mock import MagicMock

import pytest

from walgreens_client import (
    WalgreensClient,
    WalgreensAuthError,
    normalize_prescription,
    _parse_dose,
    _parse_price,
    _parse_walgreens_date,
)


# ---------------------------------------------------------------------------
# normalize_prescription tests
# ---------------------------------------------------------------------------

VALID_RX = {
    "drugName": "Clonazepam 1mg Tablets",
    "fillDate": "12/31/2025",
    "ndcNumber": "00000-0000-00",
    "pharmacist": "Phm",
    "prescriptionType": "Retail Pickup",
    "price": "$15.49",
    "quantity": "60",
    "rxNumber": "9999999-00001",
    "prescriber": {"firstName": "Jane", "lastName": "Smith", "suffix": "MD"},
    "insurance": {"claimRefNumber": "0000000000", "plan": "TESTPLAN"},
}


def test_normalize_valid_prescription():
    result = normalize_prescription(VALID_RX)
    assert result is not None
    assert result["rx_number"] == "9999999-00001"
    assert result["medication_name"] == "Clonazepam 1mg Tablets"
    assert result["dose_mg"] == 1.0
    assert result["dose_description"] == "1mg"
    assert result["quantity"] == 60
    assert result["date_filled"] == "2025-12-31T00:00:00+00:00"
    assert result["pharmacy_name"] == "Walgreens"
    assert result["prescriber_name"] == "Jane Smith MD"
    assert result["ndc_code"] == "00000-0000-00"
    assert result["rx_status"] == "Retail Pickup"
    assert result["import_source"] == "walgreens"
    assert result["walgreens_rx_id"] == "9999999-00001"


def test_normalize_missing_required():
    assert normalize_prescription({"drugName": "Test", "fillDate": "01/01/2025"}) is None


def test_normalize_non_dict():
    assert normalize_prescription("not a dict") is None


def test_normalize_no_prescriber():
    rx = {**VALID_RX}
    del rx["prescriber"]
    result = normalize_prescription(rx)
    assert result is not None
    assert result["prescriber_name"] == ""


def test_normalize_no_ndc():
    rx = {**VALID_RX}
    del rx["ndcNumber"]
    result = normalize_prescription(rx)
    assert result is not None
    assert result["ndc_code"] == ""


# ---------------------------------------------------------------------------
# _parse_dose tests
# ---------------------------------------------------------------------------

def test_parse_dose_mg():
    mg, desc = _parse_dose("Clonazepam 1mg Tablets")
    assert mg == 1.0
    assert desc == "1mg"


def test_parse_dose_decimal():
    mg, desc = _parse_dose("Zolpidem ER 12.5mg Tablets")
    assert mg == 12.5
    assert desc == "12.5mg"


def test_parse_dose_mcg():
    mg, desc = _parse_dose("Something 500mcg Capsules")
    assert mg == 0.5
    assert desc == "500mcg"


def test_parse_dose_ml():
    mg, desc = _parse_dose("Something 5ml Solution")
    assert mg == 0.0  # ml not convertible to mg
    assert desc == "5ml"


def test_parse_dose_no_match():
    mg, desc = _parse_dose("Some Drug XR")
    assert mg == 0.0
    assert desc == ""


# ---------------------------------------------------------------------------
# _parse_walgreens_date tests
# ---------------------------------------------------------------------------

def test_parse_walgreens_date():
    assert _parse_walgreens_date("12/31/2025") == "2025-12-31T00:00:00+00:00"


def test_parse_walgreens_date_invalid():
    assert _parse_walgreens_date("not-a-date") == "not-a-date"


# ---------------------------------------------------------------------------
# _parse_price tests
# ---------------------------------------------------------------------------

def test_parse_price():
    assert _parse_price("$15.49") == 15.49


def test_parse_price_zero():
    assert _parse_price("$0.00") == 0.0


def test_parse_price_comma():
    assert _parse_price("$1,234.56") == 1234.56


def test_parse_price_none():
    assert _parse_price(None) is None


def test_parse_price_empty():
    assert _parse_price("") is None


# ---------------------------------------------------------------------------
# WalgreensClient session management tests
# ---------------------------------------------------------------------------

def test_save_session_empty():
    client = WalgreensClient(username="test", password="pass")
    assert client.save_session() == "{}"


def test_load_session_valid():
    client = WalgreensClient(username="test", password="pass")
    state = json.dumps({"cookies": [{"name": "test", "value": "val"}]})
    client._load_session(state)
    assert client._storage_state is not None
    assert client._storage_state["cookies"][0]["name"] == "test"


def test_load_session_invalid():
    client = WalgreensClient(username="test", password="pass")
    client._load_session("not-json")
    assert client._storage_state is None


def test_load_session_saves_back():
    client = WalgreensClient(username="test", password="pass")
    state = {"cookies": [{"name": "sid", "value": "123"}]}
    client._load_session(json.dumps(state))
    saved = json.loads(client.save_session())
    assert saved["cookies"][0]["value"] == "123"


def test_empty_prescription_list():
    """normalize_prescription handles empty list gracefully."""
    results = [normalize_prescription(r) for r in []]
    assert results == []


# ---------------------------------------------------------------------------
# _authenticate login-failure diagnostics (F-077)
# ---------------------------------------------------------------------------

# The username typed into the form during a failed login — it must never
# surface in logs, exception messages, or screenshots (fictional per project
# fixture rules).
FIXTURE_USERNAME = "fixture-user@example.com"


def _failing_login_page():
    """Build a fake Playwright page that reaches the post-Sign-In navigation
    wait and then fails, driving _authenticate into its failure branch."""
    page = MagicMock()
    # URL carries a query string the diagnostics must strip.
    page.url = "https://www.walgreens.com/login.jsp?ru=%2Fpharmacy&err=1"
    page.title.return_value = "Sign in"
    # All selector lookups (form fields, sign-in button, error element)
    # return a truthy mock element.
    page.query_selector.return_value = MagicMock()
    # Navigation away from login.jsp never happens.
    page.wait_for_url.side_effect = Exception("nav timeout")
    # The failed-login page body echoes the account email — the client must
    # log only its length, never the text.
    page.inner_text.return_value = f"We don't recognize {FIXTURE_USERNAME}. Try again."
    page.evaluate.return_value = "UA-string"
    return page


def test_authenticate_failure_diagnostics_are_bounded_and_non_identifying(caplog):
    client = WalgreensClient(username=FIXTURE_USERNAME, password="fixture-pass")
    page = _failing_login_page()

    with caplog.at_level(logging.DEBUG, logger="walgreens_client"):
        with pytest.raises(WalgreensAuthError) as excinfo:
            client._authenticate(page)

    # No screenshot is ever taken on login failure (the old /tmp screenshot
    # persisted the filled username field indefinitely).
    page.screenshot.assert_not_called()

    # Neither the username nor any page body text reaches the logs.
    assert FIXTURE_USERNAME not in caplog.text
    assert "We don't recognize" not in caplog.text

    # Bounded, non-identifying diagnostics are logged instead.
    assert "Page body text length" in caplog.text
    assert "Page error element present" in caplog.text
    assert "URL path: /login.jsp" in caplog.text

    # The raised message carries the URL path only — no query string.
    message = str(excinfo.value)
    assert "/login.jsp" in message
    assert "ru=" not in message
    assert FIXTURE_USERNAME not in message
