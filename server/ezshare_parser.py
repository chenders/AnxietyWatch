"""Parse a ResMed AirSense 11 STR.EDF into per-day cpap_sessions dicts.

STR.EDF is the machine's cumulative daily-summary file: one value per day in
each summary signal, for the last N days the device retains. It carries
everything cpap_sessions needs, so V1 ingests STR.EDF alone (the DATALOG/
folders hold high-resolution waveforms — a deferred V2 concern).

Signal labels below were captured from a real AirSense 11 STR.EDF (firmware
2.0.7) on 2026-07-23. Medical-accuracy notes baked in here:
  * Leak signals are L/s in the file; cpap_sessions stores L/min → x60.
  * OAI/CAI/HI are apnea *indices* (events/hour); cpap_sessions stores event
    *counts* → count = round(index * usage_hours).
  * SpO2 is -1 when no oximeter is attached → NULL, never 0.
  * ResMed STR gives no per-session mask-pressure minimum, no pulse rate, and
    no RDI/RERA → those columns stay None.
  * Dates are days-since-1970 in the file; a freshly-reinitialised AS11 whose
    clock reset to epoch will report ~2008 dates — parsed faithfully; the
    clock-reset artifact is handled downstream (see earliestPlausibleDate).
"""
from __future__ import annotations

import logging
from datetime import date, timedelta
from pathlib import Path

logger = logging.getLogger(__name__)

_EPOCH = date(1970, 1, 1)

# Target metric -> exact STR.EDF signal label.
_DATE = "Date"
_DURATION = "Duration"      # minutes of use, one per day
_AHI = "AHI"
_OAI = "OAI"                # obstructive apnea index (events/hr)
_CAI = "CAI"                # central apnea index
_HI = "HI"                  # hypopnea index
_PRESS_50 = "MaskPress.50"
_PRESS_95 = "MaskPress.95"
_PRESS_MAX = "MaskPress.Max"
_LEAK_50 = "Leak.50"
_LEAK_95 = "Leak.95"
_LEAK_MAX = "Leak.Max"
_SPO2_50 = "SpO2.50"

_LEAK_LPS_TO_LPM = 60.0


def _nonneg(value):
    """Float value if present and >= 0, else None (guards the -1 sentinel)."""
    if value is None:
        return None
    v = float(value)
    return v if v >= 0 else None


def _sessions_from_reader(reader) -> list[dict]:
    """Build one cpap_sessions dict per valid day-row in an opened EDF reader."""
    labels = reader.getSignalLabels()
    idx = {lbl: i for i, lbl in enumerate(labels)}

    def col(label):
        i = idx.get(label)
        return reader.readSignal(i) if i is not None else None

    dates = col(_DATE)
    if dates is None or len(dates) == 0:
        return []
    duration = col(_DURATION)
    ahi, oai, cai, hi = col(_AHI), col(_OAI), col(_CAI), col(_HI)
    p50, p95, pmax = col(_PRESS_50), col(_PRESS_95), col(_PRESS_MAX)
    l50, l95, lmax = col(_LEAK_50), col(_LEAK_95), col(_LEAK_MAX)
    spo2 = col(_SPO2_50)

    def at(sig, i):
        return None if sig is None or i >= len(sig) else float(sig[i])

    def leak_lpm(sig, i):
        v = _nonneg(at(sig, i))
        return None if v is None else round(v * _LEAK_LPS_TO_LPM, 2)

    def count(sig, i, hours):
        v = _nonneg(at(sig, i))
        return 0 if v is None else int(round(v * hours))

    sessions = []
    for i in range(len(dates)):
        day_num = at(dates, i)
        dur = at(duration, i)
        if day_num is None or day_num <= 0 or dur is None or dur <= 0:
            continue  # empty/placeholder row — no session that day
        hours = dur / 60.0
        sessions.append({
            "date": _EPOCH + timedelta(days=int(day_num)),
            "total_usage_minutes": int(round(dur)),
            "ahi": _nonneg(at(ahi, i)),
            "obstructive_events": count(oai, i, hours),
            "central_events": count(cai, i, hours),
            "hypopnea_events": count(hi, i, hours),
            "rdi_events": None,
            "rera_events": None,
            "pressure_min": None,
            "pressure_max": _nonneg(at(pmax, i)),
            "pressure_mean": _nonneg(at(p50, i)),
            "pressure_95th": _nonneg(at(p95, i)),
            "leak_avg": leak_lpm(l50, i),
            "leak_max": leak_lpm(lmax, i),
            "leak_rate_95th": leak_lpm(l95, i),
            "spo2_avg": _nonneg(at(spo2, i)),
            "spo2_min": None,
            "pulse_avg": None,
        })
    return sessions


def parse_str_edf(path: str | Path) -> list[dict]:
    """Parse a ResMed STR.EDF file into a list of per-day cpap_sessions dicts."""
    path = Path(path)
    if not path.exists():
        return []
    import pyedflib
    reader = pyedflib.EdfReader(str(path))
    try:
        sessions = _sessions_from_reader(reader)
    finally:
        reader.close()
    logger.info("Parsed %d day(s) from %s", len(sessions), path.name)
    return sessions
