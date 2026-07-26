"""Clock-reset correction for ez Share CPAP dates.

The AirSense 11 has no patient-facing date/time setting — its clock is set
over the machine's cellular link to ResMed AirView. When that sync doesn't
happen (no signal, lapsed registration, or a power/SD event), the clock falls
back to its ~2008 epoch and every STR.EDF row is stamped years in the past.

The clock still *ticks* one day per day, so the error is a fixed whole-day
offset. We establish that offset once — anchoring the newest raw session to the
current date — persist it, and add it to every implausibly-old date. Dates that
are already plausible (the machine synced) are left untouched, so this is a
no-op once the hardware clock is correct.

Pure functions only: no DB, no wall-clock reads (callers inject the anchor
date). This keeps the logic deterministically testable.
"""
from __future__ import annotations

from datetime import date, timedelta

# The AirSense 11 launched in 2021, so any real session is well after this.
# Anything earlier is a clock-reset artifact (mirrors the iOS-side
# earliestPlausibleDate / F-028 handling for the ~2009 epoch reset).
EARLIEST_PLAUSIBLE_DATE = date(2015, 1, 1)

# Corrected dates may legitimately land slightly ahead of the anchor (timezone,
# a session that ran past midnight, poll timing), but not by much.
_FUTURE_TOLERANCE_DAYS = 2


def newest_date(sessions: list[dict]) -> date | None:
    return max((s["date"] for s in sessions), default=None)


def is_epoch_reset(sessions: list[dict],
                   threshold: date = EARLIEST_PLAUSIBLE_DATE) -> bool:
    """True if ANY session date is implausibly old (clock reset).

    Presence-based, not newest-based: an STR.EDF can hold a mix of real and
    epoch-reset rows (e.g. the machine's clock syncs to AirView partway through
    its retained history), and those old rows still need correcting even though
    the newest row is plausible.
    """
    return any(s["date"] < threshold for s in sessions)


def epoch_rows(sessions: list[dict],
               threshold: date = EARLIEST_PLAUSIBLE_DATE) -> list[dict]:
    """The subset of sessions whose dates are implausibly old (clock reset)."""
    return [s for s in sessions if s["date"] < threshold]


def compute_offset_days(sessions: list[dict], anchor_date: date) -> int:
    """Whole-day offset that maps the newest raw session onto anchor_date."""
    newest = newest_date(sessions)
    if newest is None:
        return 0
    return (anchor_date - newest).days


def offset_is_sane(sessions: list[dict], offset_days: int, anchor_date: date,
                   threshold: date = EARLIEST_PLAUSIBLE_DATE) -> bool:
    """Would applying offset_days put the newest date in a plausible window?

    Guards against a stale persisted offset after the machine's clock changes
    again (e.g. a second reset to a different epoch, or a real AirView sync).
    """
    newest = newest_date(sessions)
    if newest is None:
        return True
    corrected = newest + timedelta(days=offset_days)
    return threshold <= corrected <= anchor_date + timedelta(days=_FUTURE_TOLERANCE_DAYS)


def apply_offset(sessions: list[dict], offset_days: int,
                 threshold: date = EARLIEST_PLAUSIBLE_DATE) -> list[dict]:
    """Return sessions with implausibly-old dates shifted by offset_days.

    Dates already >= threshold are left untouched (machine clock is correct),
    so a stale offset can't corrupt already-good data. Does not mutate inputs.
    """
    if not offset_days:
        return sessions
    out = []
    for s in sessions:
        if s["date"] < threshold:
            s = {**s, "date": s["date"] + timedelta(days=offset_days)}
        out.append(s)
    return out
