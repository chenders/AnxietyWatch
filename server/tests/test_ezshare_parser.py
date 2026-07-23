"""Tests for the STR.EDF parser.

Uses MagicMock EDF readers (the house pattern in test_edf_parser.py) built with
the real ResMed AS11 signal labels + synthetic values — so no real CPAP data
(PII) is committed while still exercising the exact unit/derivation logic.
"""
from datetime import date
from unittest.mock import MagicMock

import numpy as np

from ezshare_parser import _sessions_from_reader


def _reader(signals: dict) -> MagicMock:
    labels = list(signals.keys())
    arrays = [np.array(signals[lbl], dtype=float) for lbl in labels]
    r = MagicMock()
    r.getSignalLabels.return_value = labels
    r.readSignal = lambda i: arrays[i]
    return r


def _one(**signals):
    """Build a reader for a single day with sensible Date/Duration defaults."""
    signals.setdefault("Date", [1])          # 1970-01-02
    signals.setdefault("Duration", [420])    # 7h
    return _sessions_from_reader(_reader(signals))


def test_date_from_epoch_days():
    # Date is days-since-1970; day 1 -> 1970-01-02 (trivially verifiable).
    s = _one(Date=[1], Duration=[400])
    assert s[0]["date"] == date(1970, 1, 2)


def test_leak_converted_lps_to_lpm():
    # ResMed leak is L/s in the file; cpap_sessions stores L/min -> x60.
    s = _one(**{"Leak.95": [0.5], "Leak.50": [0.1], "Leak.Max": [1.0]})
    assert abs(s[0]["leak_rate_95th"] - 30.0) < 0.01
    assert abs(s[0]["leak_avg"] - 6.0) < 0.01
    assert abs(s[0]["leak_max"] - 60.0) < 0.01


def test_apnea_index_to_count():
    # OAI is events/hour; count = round(index * usage_hours). 2/hr * 10h = 20.
    s = _one(Duration=[600], **{"OAI": [2.0], "CAI": [0.5], "HI": [1.0]})
    assert s[0]["obstructive_events"] == 20
    assert s[0]["central_events"] == 5     # round(0.5 * 10)
    assert s[0]["hypopnea_events"] == 10   # round(1.0 * 10)


def test_ahi_maps_directly_as_rate():
    s = _one(AHI=[4.2])
    assert abs(s[0]["ahi"] - 4.2) < 0.01


def test_spo2_sentinel_becomes_none():
    # -1 == no oximeter attached -> NULL, never 0.
    s = _one(**{"SpO2.50": [-1]})
    assert s[0]["spo2_avg"] is None


def test_pressure_and_null_only_fields():
    s = _one(**{"MaskPress.50": [9.9], "MaskPress.95": [11.0], "MaskPress.Max": [12.0]})
    row = s[0]
    assert abs(row["pressure_mean"] - 9.9) < 0.01
    assert abs(row["pressure_95th"] - 11.0) < 0.01
    assert abs(row["pressure_max"] - 12.0) < 0.01
    # STR gives no per-session min pressure, no pulse, no RDI/RERA:
    assert row["pressure_min"] is None
    assert row["pulse_avg"] is None
    assert row["rdi_events"] is None
    assert row["rera_events"] is None


def test_skips_zero_duration_day():
    # Two day-rows; the second has zero usage and must be dropped.
    sessions = _sessions_from_reader(_reader({
        "Date": [1, 2],
        "Duration": [400, 0],
        "AHI": [3.0, 0.0],
    }))
    assert len(sessions) == 1
    assert sessions[0]["date"] == date(1970, 1, 2)


def test_usage_minutes_rounded_int():
    s = _one(Duration=[419.6])
    assert s[0]["total_usage_minutes"] == 420
    assert isinstance(s[0]["total_usage_minutes"], int)
