"""Tests for CapRx claim normalization and upsert."""

from caprx_client import normalize_claim


class TestNormalizeClaim:
    """Tests for normalize_claim()."""

    def _make_claim(self, **overrides):
        """Build a minimal valid claim wrapper."""
        claim = {
            "drug_name": "Clonazepam",
            "date_of_service": "2024-03-15T00:00:00Z",
            "id": 12345,
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
        assert result["rx_number"] == "CRX-12345"
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
