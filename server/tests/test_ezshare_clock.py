from datetime import date, timedelta

from ezshare_clock import (
    is_epoch_reset, compute_offset_days, apply_offset, offset_is_sane,
    EARLIEST_PLAUSIBLE_DATE,
)


def _sessions(*dates):
    return [{"date": d, "ahi": 3.0} for d in dates]


def test_is_epoch_reset_true_for_2008():
    assert is_epoch_reset(_sessions(date(2008, 1, 4), date(2008, 1, 9))) is True


def test_is_epoch_reset_false_for_real_dates():
    assert is_epoch_reset(_sessions(date(2026, 7, 20), date(2026, 7, 24))) is False


def test_is_epoch_reset_false_for_empty():
    assert is_epoch_reset([]) is False


def test_compute_offset_maps_newest_to_anchor():
    sessions = _sessions(date(2008, 1, 4), date(2008, 1, 9))
    anchor = date(2026, 7, 24)
    offset = compute_offset_days(sessions, anchor)
    # newest (2008-01-09) + offset == anchor
    assert date(2008, 1, 9) + timedelta(days=offset) == anchor


def test_apply_offset_shifts_only_implausible_dates():
    offset = compute_offset_days(_sessions(date(2008, 1, 9)), date(2026, 7, 24))
    mixed = _sessions(date(2008, 1, 4), date(2008, 1, 9), date(2026, 7, 24))
    out = apply_offset(mixed, offset)
    dates = sorted(s["date"] for s in out)
    # the two 2008 rows shift forward; the already-plausible 2026 row is untouched
    assert all(d >= EARLIEST_PLAUSIBLE_DATE for d in dates)
    assert date(2026, 7, 24) in dates            # untouched
    assert dates[-1] == date(2026, 7, 24)         # newest 2008 mapped to anchor == existing 2026


def test_apply_offset_preserves_day_spacing():
    sessions = _sessions(date(2008, 1, 4), date(2008, 1, 9))
    offset = compute_offset_days(sessions, date(2026, 7, 24))
    out = sorted(s["date"] for s in apply_offset(sessions, offset))
    assert (out[1] - out[0]).days == 5           # same 5-day gap as raw
    assert out[1] == date(2026, 7, 24)


def test_apply_offset_zero_is_noop():
    sessions = _sessions(date(2008, 1, 4))
    assert apply_offset(sessions, 0) == sessions


def test_apply_offset_does_not_mutate_input():
    sessions = _sessions(date(2008, 1, 9))
    apply_offset(sessions, 100)
    assert sessions[0]["date"] == date(2008, 1, 9)


def test_offset_is_sane_accepts_good_offset():
    sessions = _sessions(date(2008, 1, 9))
    anchor = date(2026, 7, 24)
    good = compute_offset_days(sessions, anchor)
    assert offset_is_sane(sessions, good, anchor) is True


def test_offset_is_sane_rejects_stale_offset_landing_in_past():
    # Machine reset again to an even older epoch: a stale offset leaves it old.
    sessions = _sessions(date(2008, 1, 9))
    assert offset_is_sane(sessions, 10, date(2026, 7, 24)) is False


def test_offset_is_sane_rejects_offset_landing_in_future():
    sessions = _sessions(date(2008, 1, 9))
    huge = compute_offset_days(sessions, date(2030, 1, 1))
    assert offset_is_sane(sessions, huge, date(2026, 7, 24)) is False
