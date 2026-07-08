"""Tests for CapRx claim normalization and sync status hygiene."""

import logging
import os
from unittest.mock import patch
from urllib.parse import urlparse

import psycopg2
import pytest
import requests

from caprx_client import normalize_claim
from caprx_sync import run_sync, get_setting

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get("DATABASE_URL", "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test"),
)

# Guard against accidentally running destructive tests on a non-test database
# (this module writes schema.sql and DELETEs settings rows). Matches the
# refuse-unless-"test" idiom in test_alembic / test_schema / test_walgreens_sync.
_db_name = urlparse(DATABASE_URL).path.rsplit("/", 1)[-1]
if "test" not in _db_name:
    raise RuntimeError(
        f"Refusing to run destructive CapRx sync tests against '{_db_name}'. "
        "DATABASE_URL must point to a database whose name contains 'test'."
    )


class TestNormalizeClaim:
    """Tests for normalize_claim()."""

    def _make_claim(self, **overrides):
        """Build a minimal valid claim wrapper."""
        claim = {
            "drug_name": "Clonazepam",
            "date_of_service": "2024-03-15T00:00:00Z",
            "id": 9999999,
            "quantity_dispensed": 30,
            "days_supply": 30,
            "strength": "1",
            "strength_unit_of_measure": "MG",
            "dosage": "1mg tablet",
            "pharmacy_name": "Test Pharmacy #12345",
            "ndc": "00000-0000-00",
            "patient_pay_amount": "10.00",
            "plan_pay_amount": "45.50",
            "drug_type": "generic",
            "dosage_form": "tablet",
        }
        claim.update(overrides)
        return {"claim": claim}

    def test_basic_normalization(self):
        result = normalize_claim(self._make_claim())
        assert result is not None
        assert result["rx_number"] == "CRX-9999999"
        assert result["medication_name"] == "Clonazepam"
        assert result["quantity"] == 30
        assert result["days_supply"] == 30

    def test_cost_fields_parsed(self):
        result = normalize_claim(self._make_claim())
        assert result["patient_pay"] == 10.0
        assert result["plan_pay"] == 45.5

    def test_cost_fields_none_when_empty(self):
        result = normalize_claim(self._make_claim(
            patient_pay_amount="", plan_pay_amount=None
        ))
        assert result["patient_pay"] is None
        assert result["plan_pay"] is None

    def test_dosage_form_and_drug_type(self):
        result = normalize_claim(self._make_claim())
        assert result["dosage_form"] == "tablet"
        assert result["drug_type"] == "generic"

    def test_missing_drug_name_returns_none(self):
        result = normalize_claim(self._make_claim(drug_name=""))
        assert result is None

    def test_missing_claim_id_returns_none(self):
        result = normalize_claim(self._make_claim(id=""))
        assert result is None

    def test_mcg_converted_to_mg(self):
        result = normalize_claim(self._make_claim(
            strength="500", strength_unit_of_measure="MCG"
        ))
        assert result["dose_mg"] == 0.5

    def test_reversed_claim_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["claim_status"] = "reversed"
        result = normalize_claim(wrapper)
        assert result is None

    def test_rejected_claim_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["status"] = "rejected"
        result = normalize_claim(wrapper)
        assert result is None

    def test_active_claim_not_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["claim_status"] = "paid"
        result = normalize_claim(wrapper)
        assert result is not None


# ---------------------------------------------------------------------------
# run_sync status hygiene (F-078)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def _init_db():
    """Create tables once per test session."""
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    cur = conn.cursor()
    schema_path = os.path.join(os.path.dirname(__file__), "..", "schema.sql")
    with open(schema_path) as f:
        cur.execute(f.read())
    conn.close()


@pytest.fixture
def clean_caprx_state(_init_db):
    """DB connection with caprx settings/sync_log rows cleaned on both sides.

    log_sync commits internally, so rollback-based teardown isn't enough.
    """
    conn = psycopg2.connect(DATABASE_URL)

    def _cleanup():
        cur = conn.cursor()
        cur.execute("DELETE FROM settings WHERE key LIKE 'caprx_%'")
        cur.execute("DELETE FROM sync_log WHERE sync_type = 'caprx'")
        conn.commit()

    _cleanup()
    yield conn
    _cleanup()
    conn.close()


# A fake resolve_id — per the CapRx SSO flow this value is directly
# exchangeable for access+refresh tokens, so it must never be persisted.
FAKE_RESOLVE_EXC_TEXT = (
    "HTTPSConnectionPool(host='sso.example.com', port=443): "
    "Max retries exceeded with url: "
    "/sso/callback?resolve_id=FAKE-RESOLVE-XYZ-999 "
    "(Caused by NewConnectionError('...'))"
)


def test_request_exception_stores_fixed_status_only(clean_caprx_state, caplog):
    """A network failure whose exception text carries a resolve_id must store
    the fixed status string 'api_error' — the raw exception text (and the
    resolve_id in it) must appear nowhere in settings or sync_log."""
    conn = clean_caprx_state
    with patch("caprx_sync.CapRxClient") as mock_client_cls:
        mock_client_cls.return_value.authenticate.side_effect = (
            requests.exceptions.RequestException(FAKE_RESOLVE_EXC_TEXT)
        )
        with caplog.at_level(logging.ERROR, logger="caprx_sync"):
            status, count = run_sync(conn=conn, email="user@example.com", password="pw")

    assert (status, count) == ("api_error", 0)
    assert get_setting(conn, "caprx_last_status") == "api_error"

    cur = conn.cursor()
    # Nothing in settings carries the raw value.
    cur.execute("SELECT key FROM settings WHERE value LIKE %s", ("%FAKE-RESOLVE-XYZ-999%",))
    assert cur.fetchall() == []
    # A sync_log entry exists, and it carries the fixed status only.
    cur.execute("SELECT record_counts::text FROM sync_log WHERE sync_type = 'caprx'")
    rows = cur.fetchall()
    assert rows
    for (record_counts,) in rows:
        assert "FAKE-RESOLVE-XYZ-999" not in record_counts
        assert '"status": "api_error"' in record_counts

    # The server log gets the sanitized detail: URL query redacted.
    assert "CapRx auth network error" in caplog.text
    assert "FAKE-RESOLVE-XYZ-999" not in caplog.text
    assert "/sso/callback?<redacted>" in caplog.text


def test_fetch_request_exception_stores_fixed_status_only(clean_caprx_state, caplog):
    """Same guarantee for a failure during fetch_all_claims."""
    conn = clean_caprx_state
    with patch("caprx_sync.CapRxClient") as mock_client_cls:
        instance = mock_client_cls.return_value
        instance.authenticate.return_value = None
        instance.fetch_all_claims.side_effect = (
            requests.exceptions.RequestException(FAKE_RESOLVE_EXC_TEXT)
        )
        with caplog.at_level(logging.ERROR, logger="caprx_sync"):
            status, count = run_sync(conn=conn, email="user@example.com", password="pw")

    assert (status, count) == ("api_error", 0)
    assert get_setting(conn, "caprx_last_status") == "api_error"
    assert "FAKE-RESOLVE-XYZ-999" not in caplog.text


def test_missing_credentials_stores_fixed_status(clean_caprx_state):
    conn = clean_caprx_state
    with patch.dict("os.environ", {"CAPRX_USERNAME": "", "CAPRX_PASSWORD": ""}):
        status, count = run_sync(conn=conn)
    assert (status, count) == ("no_credentials", 0)
    assert get_setting(conn, "caprx_last_status") == "no_credentials"
