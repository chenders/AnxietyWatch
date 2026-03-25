"""Tests for the Walgreens prescription history client."""

from unittest.mock import patch, MagicMock

import pytest

from walgreens_client import (
    WalgreensClient,
    WalgreensAuthError,
    normalize_prescription,
    _parse_dose,
    _parse_price,
)


# ---------------------------------------------------------------------------
# normalize_prescription tests
# ---------------------------------------------------------------------------

VALID_RX = {
    "drugName": "Clonazepam 1mg Tablets",
    "fillDate": "12/31/2025",
    "ndcNumber": "00093321205",
    "pharmacist": "Phm",
    "prescriptionType": "Retail Pickup",
    "price": "$15.49",
    "quantity": "60",
    "rxNumber": "2618630-03890",
    "prescriber": {"firstName": "Robert", "lastName": "Geistwhite"},
    "insurance": {"claimRefNumber": "1221705377", "plan": "GOODRX"},
}


def test_normalize_valid_prescription():
    result = normalize_prescription(VALID_RX)
    assert result is not None
    assert result["rx_number"] == "2618630-03890"
    assert result["medication_name"] == "Clonazepam 1mg Tablets"
    assert result["dose_mg"] == 1.0
    assert result["dose_description"] == "1mg"
    assert result["quantity"] == 60
    assert result["date_filled"] == "2025-12-31T00:00:00+00:00"
    assert result["pharmacy_name"] == "Walgreens"
    assert result["prescriber_name"] == "Robert Geistwhite"
    assert result["ndc_code"] == "00093321205"
    assert result["rx_status"] == "Retail Pickup"
    assert result["import_source"] == "walgreens"
    assert result["walgreens_rx_id"] == "2618630-03890"


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
    from walgreens_client import _parse_walgreens_date
    assert _parse_walgreens_date("12/31/2025") == "2025-12-31T00:00:00+00:00"


def test_parse_walgreens_date_invalid():
    from walgreens_client import _parse_walgreens_date
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
# WalgreensClient tests (mocked HTTP)
# ---------------------------------------------------------------------------

def _make_mock_session():
    """Create a mock requests.Session with cookie support."""
    session = MagicMock()
    session.headers = {}
    session.cookies = MagicMock()

    # Mock cookie access
    xsrf_cookie = MagicMock()
    xsrf_cookie.name = "XSRF-TOKEN"
    xsrf_cookie.value = "fake-xsrf-token"
    xsrf_cookie.domain = ".walgreens.com"
    xsrf_cookie.path = "/"

    session_id_cookie = MagicMock()
    session_id_cookie.name = "session_id"
    session_id_cookie.value = "fake-session-id"
    session_id_cookie.domain = ".walgreens.com"
    session_id_cookie.path = "/"

    session.cookies.__iter__ = MagicMock(return_value=iter([xsrf_cookie, session_id_cookie]))
    session.cookies.get.return_value = "fake-xsrf-token"

    return session


@patch("walgreens_client.requests.Session")
def test_fetch_prescriptions_returns_list(mock_session_cls):
    mock_session = _make_mock_session()
    mock_session_cls.return_value = mock_session

    # Login page GET
    login_page = MagicMock()
    login_page.status_code = 200

    # Login POST
    login_resp = MagicMock()
    login_resp.status_code = 200
    login_resp.json.return_value = {"status": "success"}

    # 2FA option POST
    twofa_option = MagicMock()
    twofa_option.status_code = 200

    # 2FA answer POST
    twofa_answer = MagicMock()
    twofa_answer.status_code = 200

    # printrx/load POST
    rx_resp = MagicMock()
    rx_resp.status_code = 200
    rx_resp.json.return_value = {"rxRecords": [VALID_RX]}

    mock_session.get.return_value = login_page
    mock_session.post.side_effect = [login_resp, twofa_option, twofa_answer, rx_resp]

    client = WalgreensClient(
        username="test@example.com",
        password="pass",
        security_answer="test-answer",
    )
    results = client.fetch_prescriptions()

    assert len(results) == 1
    assert results[0]["rx_number"] == "2618630-03890"


@patch("walgreens_client.requests.Session")
def test_auth_failure_raises(mock_session_cls):
    mock_session = _make_mock_session()
    mock_session_cls.return_value = mock_session

    login_page = MagicMock()
    login_page.status_code = 200
    mock_session.get.return_value = login_page

    login_resp = MagicMock()
    login_resp.status_code = 401
    mock_session.post.return_value = login_resp

    client = WalgreensClient(username="bad@example.com", password="wrong")
    with pytest.raises(WalgreensAuthError, match="Invalid credentials"):
        client.fetch_prescriptions()


@patch("walgreens_client.requests.Session")
def test_session_reuse_skips_login(mock_session_cls):
    mock_session = _make_mock_session()
    mock_session_cls.return_value = mock_session

    rx_resp = MagicMock()
    rx_resp.status_code = 200
    rx_resp.json.return_value = {"rxRecords": [VALID_RX]}
    mock_session.post.return_value = rx_resp

    client = WalgreensClient(username="test@example.com", password="pass")
    saved = '[{"name":"XSRF-TOKEN","value":"saved","domain":".walgreens.com","path":"/"}]'
    results = client.fetch_prescriptions(session_data=saved)

    assert len(results) == 1
    # Should not have called GET (login page) since session was reused
    mock_session.get.assert_not_called()


@patch("walgreens_client.requests.Session")
def test_expired_session_falls_back_to_login(mock_session_cls):
    mock_session = _make_mock_session()
    mock_session_cls.return_value = mock_session

    # First POST (session reuse) returns 401
    expired_resp = MagicMock()
    expired_resp.status_code = 401

    login_page = MagicMock()
    login_page.status_code = 200

    login_resp = MagicMock()
    login_resp.status_code = 200
    login_resp.json.return_value = {"status": "success"}

    rx_resp = MagicMock()
    rx_resp.status_code = 200
    rx_resp.json.return_value = {"rxRecords": []}

    mock_session.get.return_value = login_page
    mock_session.post.side_effect = [expired_resp, login_resp, rx_resp]

    client = WalgreensClient(username="test@example.com", password="pass")
    saved = '[{"name":"XSRF-TOKEN","value":"old","domain":".walgreens.com","path":"/"}]'
    results = client.fetch_prescriptions(session_data=saved)

    assert results == []
    # Should have called GET for login page after session expired
    mock_session.get.assert_called_once()


@patch("walgreens_client.requests.Session")
def test_network_error_wrapped(mock_session_cls):
    mock_session = _make_mock_session()
    mock_session_cls.return_value = mock_session

    mock_session.get.side_effect = Exception("Connection refused")

    client = WalgreensClient(username="test@example.com", password="pass")
    with pytest.raises(WalgreensAuthError):
        client.fetch_prescriptions()


def test_empty_prescription_list():
    """normalize_prescription handles empty list gracefully."""
    results = [normalize_prescription(r) for r in []]
    assert results == []
