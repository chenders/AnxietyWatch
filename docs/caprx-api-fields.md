# CapRx API Response Fields

**Last updated:** 2026-03-30
**Source:** `server/caprx_client.py` — `normalize_claim()` function

## How to discover new fields

The `normalize_claim()` function logs all available keys at INFO level
on the first claim processed each sync. Check server logs after a sync:

```
CapRx claim wrapper keys: ['claim', ...]
CapRx claim keys: ['date_of_service', 'dosage', 'drug_name', ...]
```

## Known Fields

### Claim wrapper (`claim_wrapper`)

| Key | Description |
|-----|-------------|
| `claim` | Nested dict containing all claim data fields |

### Claim data (`claim_wrapper["claim"]`)

| Key | Type | Used? | Description |
|-----|------|-------|-------------|
| `id` | int | Yes | Unique claim ID (used to build `rx_number` as `CRX-{id}`) |
| `drug_name` | str | Yes | Generic drug name (PBM adjudication name) |
| `date_of_service` | str | Yes | Fill date (ISO-8601 with Z) |
| `quantity_dispensed` | int | Yes | Number of units dispensed |
| `days_supply` | int | Yes | Days of medication supply |
| `strength` | str | Yes | Numeric strength value |
| `strength_unit_of_measure` | str | Yes | Unit: MG, MCG, etc. |
| `dosage` | str | Yes | Human-readable dosage string |
| `pharmacy_name` | str | Yes | Pharmacy name |
| `ndc` | str | Yes | National Drug Code |
| `patient_pay_amount` | str | Yes | Patient copay (as string, parsed to float) |
| `plan_pay_amount` | str | Yes | Insurance payment (as string, parsed to float) |
| `drug_type` | str | Yes | brand / generic / specialty |
| `dosage_form` | str | Yes | tablet / capsule / solution / etc. |
| `claim_status` / `status` | str | Yes | Claim status — "reversed"/"rejected" claims are filtered out |

### Fields not yet observed

These fields likely exist but have not been confirmed:

- `prescriber_npi` — Prescriber NPI number
- `pharmacy_npi` / `pharmacy_ncpdp` — Pharmacy identifiers
- `daw_code` — Dispense As Written code
- `therapeutic_class` — Drug classification code

Run a sync with `--verbose` and check logged keys to discover additional fields.
