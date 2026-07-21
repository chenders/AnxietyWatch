"""Table-driven tests for the conservative server-side SpO2 backstop.

Deterministic and pure: every sample is built off a fixed reference instant, no
wall-clock is read, and the raise decision is asserted case by case. Test values
are derived from the module constants (SPO2_FLOOR / SUSTAIN_SECONDS /
MAX_GAP_SECONDS) rather than re-typed literals, so the suite tracks any future
retune of the thresholds instead of silently drifting from them.

All data is obviously fictional (a synthetic overnight desaturation trace).
"""

from datetime import datetime, timedelta, timezone

import pytest

from backstop import (
    BackstopVerdict,
    MAX_GAP_SECONDS,
    SPO2_CHANNEL,
    SPO2_FLOOR,
    SUSTAIN_SECONDS,
    Sample,
    evaluate,
)

# Fixed reference instant (fictional overnight monitoring session).
REF = datetime(2026, 7, 20, 3, 0, 0, tzinfo=timezone.utc)
# Injected "current time"; far enough after the trace that it never matters
# (the backstop's decision is independent of `now` by design).
NOW = REF + timedelta(seconds=600)

SUSTAIN = int(SUSTAIN_SECONDS)   # 90
MAX_GAP = int(MAX_GAP_SECONDS)   # 5
DENSE_STEP = 1                   # 1 Hz nominal upload cadence, well under MAX_GAP
LOW = SPO2_FLOOR - 5.0           # clearly below the floor (dangerous)
NORMAL = SPO2_FLOOR + 10.0       # clearly above the floor (recovered)


def _spo2(offset_s, value):
    """An SpO2 sample `offset_s` seconds after REF."""
    return Sample(REF + timedelta(seconds=offset_s), SPO2_CHANNEL, value)


def _run(start_s, end_s, step_s, value):
    """A run of SpO2 samples over [start_s, end_s] inclusive, every step_s."""
    return [_spo2(t, value) for t in range(start_s, end_s + 1, step_s)]


# (id, samples, expected_raised)
CASES = [
    # (1) Sustained low, gap-free (1 Hz) over the full sustain window -> raise.
    (
        "sustained_low_gap_free_raises",
        _run(0, SUSTAIN, DENSE_STEP, LOW),
        True,
    ),
    # (2) A brief dip well under the sustain window, then recovery -> no raise.
    (
        "brief_dip_then_recovery_no_raise",
        _run(0, SUSTAIN // 3, DENSE_STEP, LOW) + [_spo2(SUSTAIN // 3 + 1, NORMAL)],
        False,
    ),
    # (3) Two low samples bracketing a blackout far larger than MAX_GAP: the
    #     span between them exceeds SUSTAIN, but the gap guard refuses to bridge
    #     missing data -> no raise. (Core safety invariant.)
    (
        "low_samples_bracketing_blackout_no_raise",
        [_spo2(0, LOW), _spo2(2 * SUSTAIN, LOW)],
        False,
    ),
    # (4) Empty window -> no raise.
    (
        "empty_window_no_raise",
        [],
        False,
    ),
    # (5) A gap-free low run shorter than the sustain window -> no raise.
    (
        "short_low_run_no_raise",
        _run(0, SUSTAIN - 30, DENSE_STEP, LOW),
        False,
    ),
    # (6) Sustained low overall (two ~45 s halves = 90 s of low readings) but
    #     split by one intra-run gap just over MAX_GAP -> no raise.
    (
        "intra_run_gap_over_max_no_raise",
        _run(0, SUSTAIN // 2, MAX_GAP, LOW)
        + _run(SUSTAIN // 2 + MAX_GAP + 1, SUSTAIN + MAX_GAP + 1, MAX_GAP, LOW),
        False,
    ),
    # (7) Boundary: gaps exactly equal to MAX_GAP are contiguous (only a gap
    #     strictly greater than MAX_GAP breaks a run) -> raise.
    (
        "gap_exactly_max_gap_raises",
        _run(0, SUSTAIN, MAX_GAP, LOW),
        True,
    ),
    # (8) A recovery above the floor mid-trace resets the sustain, even though
    #     the two low halves together exceed SUSTAIN -> no raise. ("Stays below"
    #     means continuously below.)
    (
        "recovery_splits_sustain_no_raise",
        _run(0, 60, MAX_GAP, LOW) + [_spo2(63, NORMAL)] + _run(66, 126, MAX_GAP, LOW),
        False,
    ),
    # (9) A fully-completed sustained run that then recovers still raises: the
    #     backstop is stateless and reports the observed sustained low; clearing
    #     is the caller's / heartbeat monitor's concern.
    (
        "completed_sustain_then_recovery_still_raises",
        _run(0, SUSTAIN, DENSE_STEP, LOW) + [_spo2(SUSTAIN + 3, NORMAL)],
        True,
    ),
    # (10) A sustained LOW value on a non-SpO2 channel (e.g. bradycardic HR) is
    #      ignored: the SpO2 backstop keys only on the SpO2 channel -> no raise.
    (
        "non_spo2_channel_ignored",
        [
            Sample(REF + timedelta(seconds=t), "HR", LOW)
            for t in range(0, SUSTAIN + 1, DENSE_STEP)
        ],
        False,
    ),
]


@pytest.mark.parametrize(
    "samples, expected",
    [(samples, expected) for _id, samples, expected in CASES],
    ids=[_id for _id, _samples, _expected in CASES],
)
def test_backstop_raise_decision(samples, expected):
    verdict = evaluate(samples, NOW)
    assert isinstance(verdict, BackstopVerdict)
    assert verdict.raised is expected, (verdict.reason, verdict.sustained_seconds)


def test_sustained_seconds_reports_run_length():
    """A raising verdict reports the observed run span (epsilon compare)."""
    verdict = evaluate(_run(0, SUSTAIN, DENSE_STEP, LOW), NOW)
    assert verdict.raised is True
    assert abs(verdict.sustained_seconds - float(SUSTAIN)) < 1e-6


def test_evaluated_at_echoes_injected_now():
    """`now` is recorded for the channel-health surface."""
    verdict = evaluate([], NOW)
    assert verdict.evaluated_at == NOW


def test_now_does_not_change_the_decision():
    """The raise decision is independent of `now` (the caller owns recency)."""
    samples = _run(0, SUSTAIN, DENSE_STEP, LOW)
    early = evaluate(samples, REF - timedelta(days=1))
    late = evaluate(samples, REF + timedelta(days=1))
    assert early.raised is True and late.raised is True
    assert abs(early.sustained_seconds - late.sustained_seconds) < 1e-6


def test_unsorted_input_is_handled():
    """Out-of-order samples still evaluate correctly (the backstop sorts)."""
    ordered = _run(0, SUSTAIN, DENSE_STEP, LOW)
    shuffled = list(reversed(ordered))
    assert evaluate(shuffled, NOW).raised is True


def test_reason_is_populated_for_each_branch():
    """Every branch yields a non-empty, human-readable reason."""
    raised = evaluate(_run(0, SUSTAIN, DENSE_STEP, LOW), NOW)
    empty = evaluate([], NOW)
    above = evaluate(_run(0, SUSTAIN, DENSE_STEP, NORMAL), NOW)
    short = evaluate(_run(0, SUSTAIN - 30, DENSE_STEP, LOW), NOW)
    for verdict in (raised, empty, above, short):
        assert isinstance(verdict.reason, str) and verdict.reason
